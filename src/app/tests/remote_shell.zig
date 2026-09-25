//! Root integration tests for remote workflows and shell effects.

const std = @import("std");
const chasen = @import("chasen");

const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_push_retry = @import("../push_retry.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const app_view = @import("../view.zig");
const effect_origin = @import("../effect_origin.zig");
const page = @import("../page.zig");
const repo_session = @import("../repo_session.zig");
const changes_page = @import("../pages/changes.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const content_selection = @import("../diff_surface/selection.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const shell_effects = @import("../shell_effects.zig");
const workflow_remote = @import("../workflow/remote.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_source = @import("../../diff/source.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_ops = @import("../git_ops.zig");
const git_remote = @import("../../git/remote.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");

const App = app_mod.App;

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

fn branchStatusBundleForRemoteRootTest(
    allocator: std.mem.Allocator,
    oid: []const u8,
    branch: []const u8,
    upstream: []const u8,
) !git_branch_status.BranchStatusBundle {
    var builder = git_branch_status.Builder.init(allocator);
    errdefer builder.deinit();
    try builder.setOid(oid);
    try builder.setBranchHead(branch);
    try builder.setUpstream(upstream);
    builder.setAheadBehind(1, 0);
    return builder.finish();
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

fn beginAcceptedTestAction(
    app: *App,
    kind: app_actions.ActionKind,
) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    const prepared = actionLifecycle(app).prepare(kind);
    const pending = actionLifecycle(app).acceptSpawn(app.allocator.?, prepared).pending;
    switch (kind) {
        .pull, .fetch => app.remote_workflow.action_control.begin(pending.generation),
        .switch_branch => app.remote_workflow.branch_switch_pending = .{
            .token = pending,
            .owner = .{
                .origin = remoteWorkflow(app).branch_origin.?,
                .root_identity = app.repo_session.view().activeIdentity() orelse test_action_root_identity,
            },
        },
        else => {},
    }
    return pending;
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
    return app.pages.changes.activation.activate(app.repo_session.view().epoch(), source_member, auxiliary, auxiliary);
}

fn changesNavigationView(app: *const App) changes_navigation.View {
    const body = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = body.width, .height = body.height },
    };
}

fn changesNavigation(app: *App) changes_navigation.Controller {
    const view = changesNavigationView(app);
    return .{
        .page = &app.pages.changes,
        .repo_root = view.repo_root,
        .repo_epoch = view.repo_epoch,
        .root_identity = view.root_identity,
        .source = view.source,
        .layout = view.layout,
        .diagnostics = .{ .target = &app.pages.changes.status },
    };
}

fn changesReload(app: *App) changes_reload.Controller {
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigation(app),
        .source = app.config.source,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
    };
}

fn changesOperations(app: *const App) changes_operations.View {
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigationView(app),
        .source = app.config.source,
        .repo_root = app.repo_session.view().activeRoot(),
        .activation_state = app.pages.changes.activation.state,
    };
}

fn changesOperationController(app: *App) changes_operations.Controller {
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigation(app),
        .view_state = changesOperations(app),
    };
}

fn shellEffectOrigins(app: *const App) shell_effects.OriginContext {
    const repo_epoch = app.repo_session.view().epoch();
    const changes_identity = app.pages.changes.activation.currentIdentity();
    const compare_identity = app.pages.compare.activation.currentIdentity();
    return .{
        .snapshot = .{
            .active_page = app.active_page,
            .repo_epoch = repo_epoch,
            .changes_activation_id = app.pages.changes.activation.next_activation_id,
            .repository_activation_id = app.pages.repository.activation_id,
            .history_activation_id = app.pages.history.activation.next_activation_id,
            .compare_activation_id = app.pages.compare.activation.next_activation_id,
            .remote_error_instance_id = if (app.overlay.isRemoteError()) app.overlay.remote_error_instance_id else null,
            .commit_panel_instance_id = app.local_workflow.view().commitPanelInstanceId(),
        },
        .changes_repo_epoch = if (changes_identity) |identity| identity.repo_epoch else repo_epoch,
        .repository_repo_epoch = app.pages.repository.repo_epoch,
        .history_repo_epoch = app.pages.history.repo_epoch,
        .compare_repo_epoch = if (compare_identity) |identity| identity.repo_epoch else repo_epoch,
    };
}

fn currentChangesActionRoot(app: *const App) ?[]const u8 {
    if (app.active_page != .changes or app.pages.changes.activation.currentIdentity() == null or diff_source.sourceIsOneShotInput(app.config.source)) return null;
    return app.repo_session.view().activeRoot();
}

fn remoteWorkflow(app: *App) workflow_remote.Controller {
    const origins = shellEffectOrigins(app);
    return .{
        .state = &app.remote_workflow,
        .lifecycle = actionLifecycle(app),
        .operations = changesOperationController(app),
        .repo = app.repo_session.view(),
        .current_changes_root = currentChangesActionRoot(app),
        .env_map = app.env_map,
        .active_page = app.active_page,
        .changes_origin = origins.changes(),
        .branch_origin = switch (app.active_page) {
            .changes => origins.changes(),
            .repository => origins.repository(),
            .history => origins.history(),
            .compare => origins.compare(),
            else => null,
        },
        .repository_status = &app.pages.repository.status,
        .history_status = &app.pages.history.status,
        .compare_status = &app.pages.compare.status,
        .effect_snapshot = origins.snapshot,
        .status = &app.pages.changes.status,
        .overlay = &app.overlay,
        .redraw = .{ .skip_requested = &app.redraw_plan.skip_requested },
    };
}

fn shellEffects(app: *App) shell_effects.Controller {
    return .{
        .state = &app.shell_effects_state,
        .user_config = &app.user_config,
        .env_map = app.env_map,
        .origins = shellEffectOrigins(app),
        .diagnostics = .{
            .shell = &app.status,
            .changes = &app.pages.changes.status,
            .repository = &app.pages.repository.status,
            .compare = &app.pages.compare.status,
        },
        .redraw = .{ .skip_requested = &app.redraw_plan.skip_requested },
    };
}

fn copySourceSelection(app: *App, ctx: *chasen.Ctx(App.Msg), text: []const u8) void {
    shellEffects(app).queueClipboard(ctx, .{
        .origin = .{ .page = shellEffects(app).repositoryOrigin() },
        .label = "source selection",
        .text = text,
    });
}

fn copySourceHeaderPath(app: *App, ctx: *chasen.Ctx(App.Msg), path: []const u8) void {
    shellEffects(app).queueClipboard(ctx, .{
        .origin = .{ .page = shellEffects(app).repositoryOrigin() },
        .label = "file path",
        .text = path,
    });
}

fn repoSession(app: *App) repo_session.Controller {
    const home = if (app.env_map) |map| blk: {
        const value = map.get("HOME") orelse break :blk null;
        break :blk if (value.len == 0) null else value;
    } else null;
    return .{
        .state = &app.repo_session,
        .status = &app.status,
        .active_page = app.active_page,
        .source = app.config.source,
        .home = home,
        .action_pending = app.action_runtime.view().hasPending(),
        .changes = .{ .page = &app.pages.changes, .navigation = changesNavigation(app), .reload = changesReload(app) },
        .repository = .{ .page = &app.pages.repository },
        .compare = .{ .page = &app.pages.compare },
        .shell = app.remote_workflow.repositoryInvalidationPort(&app.overlay),
    };
}

fn commitDiscovery(
    app: *App,
    allocator: std.mem.Allocator,
    result: repo_discovery.DiscoveryResult,
    active_index: usize,
    origin: repo_session.CommitOrigin,
) !repo_session.CommitOutcome {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    return repoSession(app).commitDiscovered(&ctx, result, active_index, origin);
}

fn mutationFenceRepoTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !App {
    var app: App = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
    };
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    _ = activateChanges(&app);
    return app;
}

fn replaceMutationFenceTestRepo(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state = .{
        .discovery = try testSingleRepoDiscovery(allocator, repo_root),
    };
    errdefer {
        app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state = .{};
    }
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    app.repo_session.repo_epoch +%= 1;
    app.pages.changes.activation.deactivate();
    _ = activateChanges(app);
}

fn installInteractivePushRetryForFenceTest(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    oid: []const u8,
) !void {
    const repository = app.repo_session.view();
    try workflow_remote.testing.setRemoteErrorWithRetry(remoteWorkflow(app), allocator, .push, "failed", .{
        .repo_epoch = repository.epoch(),
        .root_identity = repository.activeIdentity().?,
        .mode = .set_upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, oid),
    });
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

fn testSessionHunkMarkKey(
    source_session_revision: u64,
    display_hunk_index: usize,
) git_ops.SessionHunkMarkKey {
    return .{
        .content = .{
            .repo_epoch = 0,
            .root_identity = null,
            .source = content_selection.SourceBasis.init(.unstaged),
            .source_session_revision = source_session_revision,
            .display = .{ .loaded = .init("test diff") },
        },
        .display_hunk_index = display_hunk_index,
    };
}

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    app.pages.changes.search.input = .{};
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn runOnlyPushInspectionTaskForTest(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    io: std.Io,
) !void {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    try app.update(msg, ctx);
}

fn deinitOnlyPushInspectionTaskForTest(
    ctx: *chasen.Ctx(App.Msg),
    io: std.Io,
) !void {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    var msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    msg.deinitUndelivered(ctx.allocator());
}

fn clearPendingRepositoryTasks(
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
) void {
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

fn runAppTestGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.Io.Dir,
) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .dir = cwd } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn appGitOutputAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.GitCommandFailed;
}

fn setupPushRetryRepoForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
) !struct { repo_root: []u8, oid: []u8 } {
    try tmp.dir.createDir(io, "remote.git", .default_dir);
    var remote = try tmp.dir.openDir(io, "remote.git", .{});
    defer remote.close(io);
    try runAppTestGit(allocator, io, &.{ "git", "init", "--bare" }, remote);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runAppTestGit(allocator, io, &.{ "git", "remote", "add", "origin", "../remote.git" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "README.md" }, work);
    try runAppTestGit(allocator, io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    const repo_root_z = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root_z);
    const repo_root = try allocator.dupe(u8, repo_root_z);
    errdefer allocator.free(repo_root);
    const oid_output = try appGitOutputAlloc(allocator, io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    errdefer allocator.free(oid_output);
    const oid = try allocator.dupe(u8, std.mem.trim(u8, oid_output, " \t\r\n"));
    allocator.free(oid_output);
    return .{ .repo_root = repo_root, .oid = oid };
}
test "Changes mutation read fence follows interactive foreground queue and terminal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    const DummyForeground = struct {
        fn done(_: chasen.ForegroundCommandResult) App.Msg {
            return .quit;
        }
    };

    // Queue rejection never crosses the accepted action/fence boundary.
    {
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer remoteWorkflow(&app).clearRemoteError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_rejection =
            app.pages.changes.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        _ = try ctx.terminal().runForegroundCommand(.{
            .argv = &.{"true"},
            .cwd = .inherit,
            .environment = .inherit,
            .finished = DummyForeground.done,
        });

        try app.update(.run_interactive_push, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
        try std.testing.expect(
            app.pages.changes.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expect(
            app.pages.changes.repository_read_authority.epoch.eql(
                epoch_before_rejection,
            ),
        );
        try std.testing.expectEqual(
            @as(u8, 1),
            ctx._pending_foreground_commands_len,
        );
    }

    // An accepted foreground command closes the fence only after the runtime
    // queue owns it. Its exact completion reopens before starting the matching
    // repository replacement.
    {
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer remoteWorkflow(&app).clearRemoteError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_launch =
            app.pages.changes.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app.update(.run_interactive_push, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
        const epoch_advanced =
            app.pages.changes.repository_read_authority.epoch.eql(
                epoch_before_launch.next(),
            );
        const entry =
            ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
        const completion = entry.finished(.{
            .request_id = entry.request_id,
            .outcome = .{ .exited = 1 },
        });
        ctx.runtimeClearPendingEffectCopies();
        try app.update(completion, &ctx);

        try std.testing.expect(fence_closed);
        try std.testing.expect(epoch_advanced);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.changes.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    }

    // The same accepted foreground owner can become detached before delivery.
    // Its exact terminal still reopens, but must discard the action fallback
    // before the common postlude can target the newly active repository.
    {
        var roots = try TestRepoPair.init();
        defer roots.deinit();
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer remoteWorkflow(&app).clearRemoteError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app.update(.run_interactive_push, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
        const entry =
            ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
        const completion = entry.finished(.{
            .request_id = entry.request_id,
            .outcome = .{ .exited = 1 },
        });
        ctx.runtimeClearPendingEffectCopies();
        try replaceMutationFenceTestRepo(&app, allocator, roots.a);
        try app.update(completion, &ctx);

        try std.testing.expect(fence_closed);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.changes.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
        try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);
    }
}

test "remote request preparation failures clear prior local confirmation" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    // A valid remote request owns the confirmation-exclusivity boundary even
    // when its first allocation fails. Local state must not survive only
    // because the typed success outcome could not be returned.
    var failure_app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer failure_app.pages.changes.deinit(allocator);
    defer failure_app.repo_session.repo_state.deinit(allocator);
    defer failure_app.remote_workflow.deinit(allocator);
    defer if (failure_app.local_workflow.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
    var branch = try branchStatusBundleForRemoteRootTest(
        allocator,
        "abc123",
        "feature",
        "origin/main",
    );
    try failure_app.pages.changes.branch_status.replace(roots.a, &branch);
    _ = failure_app.pages.changes.activation.activate(failure_app.repo_session.repo_epoch, .fresh, .fresh, .fresh);
    failure_app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src/app.zig"),
    };
    failure_app.overlay.openDiscardFile();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };

    try std.testing.expectError(
        error.OutOfMemory,
        failure_app.update(.{ .changes = .request_push }, &failing_ctx),
    );
    try std.testing.expect(failure_app.local_workflow.discard_confirmation == null);
    try std.testing.expect(!failure_app.overlay.isDiscardFile());
    try std.testing.expect(failure_app.remote_workflow.push_confirmation == null);

    var status = try git_status.StatusBundle.parseOwned(allocator, "");
    try failure_app.pages.changes.git_status.replace(roots.a, &status);
    _ = failure_app.pages.changes.activation.activate(failure_app.repo_session.repo_epoch, .fresh, .fresh, .fresh);
    failure_app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src/app.zig"),
    };
    failure_app.overlay.openDiscardFile();
    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) App.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskFailure) App.Msg {
            return .quit;
        }
    };
    var saturated_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    for (0..16) |_| try saturated_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

    try std.testing.expectError(
        error.TaskLimitExceeded,
        failure_app.update(.request_branch_switch, &saturated_ctx),
    );
    try std.testing.expect(failure_app.local_workflow.discard_confirmation == null);
    try std.testing.expect(!failure_app.remote_workflow.branch_switch.hasState());
    try std.testing.expect(failure_app.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!failure_app.overlay.isSwitchBranch());
    try std.testing.expectEqual(@as(usize, 16), saturated_ctx.takePendingTasks().len);
}

test "repository selection copy uses Repository origin without opening AI UI" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    copySourceSelection(&app, &ctx, "selected source");

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("selected source", entry.text);
    const state = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(page.Id.repository, state.origin.page.page_id);
    try std.testing.expectEqual(@as(u64, 4), state.origin.page.repo_epoch);
    try std.testing.expectEqual(@as(u64, 5), state.origin.page.activation_id);
    try std.testing.expectEqual(app_state.OverlayKind.none, app.overlay.kind);
}

test "repository source header copy uses byte-exact Repository clipboard effect" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    const path = "src/\xff-main.zig";

    copySourceHeaderPath(&app, &ctx, path);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualSlices(u8, path, entry.text);
    const state = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqualStrings("file path", state.label);
    try std.testing.expectEqual(page.Id.repository, state.origin.page.page_id);
    try std.testing.expectEqual(@as(u64, 4), state.origin.page.repo_epoch);
    try std.testing.expectEqual(@as(u64, 5), state.origin.page.activation_id);
    try std.testing.expectEqual(app_state.OverlayKind.none, app.overlay.kind);
}

test "repository selection clipboard queue failure retains page candidate" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
            .completed_selection = .{
                .token = .{
                    .repo_epoch = 4,
                    .root_identity = .{ .device = 6, .inode = 7 },
                    .path = try allocator.dupe(u8, "main.zig"),
                    .source_fingerprint = .init("selected source"),
                },
                .mode = .line,
                .range = .{
                    .start = repository_selection.pointFromLine(0),
                    .end = repository_selection.pointFromLine(0),
                },
                .source_start = 1,
                .source_end = 1,
                .line_count = 1,
                .text = try allocator.dupe(u8, "selected source"),
            },
        } },
    };
    defer app.pages.repository.deinit(allocator);
    defer app.shell_effects_state.clipboard_copies.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    for (0..4) |_| {
        _ = try ctx.terminal().copyToClipboard(.{
            .text = "occupied",
            .finished = App.Msg.clipboardFinished,
        });
    }

    copySourceSelection(&app, &ctx, app.pages.repository.completed_selection.?.text);

    try std.testing.expectEqual(@as(u8, 4), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(@as(usize, 0), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("selected source", app.pages.repository.completed_selection.?.text);
    try std.testing.expectEqualStrings("clipboard copy already queued", app.pages.repository.status.text());
}

test "copyPopup queues remote error message text" {
    var app: App = .{
        .remote_workflow = .{
            .remote_error_operation = .push,
            .remote_error_message = try std.testing.allocator.dupe(u8, "  fatal\nline two  "),
        },
    };
    defer std.testing.allocator.free(app.remote_workflow.remote_error_message.?);
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openRemoteError(.changes);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.copy_popup, &ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("  fatal\nline two  ", entry.text);
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.Msg.clipboardFinished), entry.finished);
    const state = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(app.overlay.remote_error_instance_id, state.origin.shell_surface.instance_id);
}

test "copyPopup reports empty target outside copyable popup" {
    var app: App = .{};
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.copy_popup, &ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: popup", app.status.text());
}

test "copyCommitMessage queues formatted commit message text" {
    var app: App = .{
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.replaceDraft("  subject  ", "  body\n\nline two  ");

    try app.update(.copy_commit_message, &ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("subject\n\nbody\n\nline two", entry.text);
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.Msg.clipboardFinished), entry.finished);
    const state = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(app.local_workflow.commit_panel.instance_id, state.origin.shell_surface.instance_id);
}

test "copyCommitMessage uses same commit panel state for amend mode" {
    var app: App = .{
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.local_workflow.commit_panel.open(.amend);
    app.local_workflow.commit_panel.replaceDraft("amend subject", null);

    try app.update(.copy_commit_message, &ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("amend subject", ctx._pending_clipboard_copies[0].text);
}

test "copyCommitMessage preserves body-only formatMessage shape" {
    var app: App = .{
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.replaceDraft("", "body");

    try app.update(.copy_commit_message, &ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("\n\nbody", ctx._pending_clipboard_copies[0].text);
}

test "copyCommitMessage reports empty draft and closed panel" {
    var app: App = .{
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.commit_panel.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.copy_commit_message, &ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());

    app.local_workflow.commit_panel.open(.commit);
    try app.update(.copy_commit_message, &ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());
}

test "finishSwitchBranch success clears repo-local changes state and reloads matching repo" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = activateChanges(&app);
    defer app.pages.changes.reviewed_store.deinit(allocator);
    defer app.pages.changes.staged_hunks.deinit(allocator);
    defer changesNavigation(&app).clearActionCursor(allocator);
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);

    try app.pages.changes.reviewed_store.set(allocator, app.repo_session.view().activeRoot(), app_test_support.files_two[0], true);
    try app.pages.changes.staged_hunks.addExact(allocator, roots.a, "a", testSessionHunkMarkKey(1, 0));
    try installTestActionCursor(&app, allocator, .file, "a", 99);
    setDiffSearchQuery(&app, "needle");

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .action_finished = .{ .switch_branch = .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(!try app.pages.changes.reviewed_store.containsFile(allocator, app.repo_session.view().activeRoot(), app_test_support.files_two[0]));
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.staged_hunks.items.items.len);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.search.query.len);
    try std.testing.expectEqualStrings("switched branch: main -> feature", app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
}

test "finishSwitchBranch failure owns full details and allows closing and reopening picker" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 32 },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    defer app.remote_workflow.deinit(allocator);
    defer app.shell_effects_state.clipboard_copies.deinit(allocator);
    _ = activateChanges(&app);
    try app.pages.changes.staged_hunks.addExact(allocator, roots.a, "a", testSessionHunkMarkKey(1, 0));
    setDiffSearchQuery(&app, "needle");

    const details = "error: Your local changes would be overwritten by checkout:\n" ++
        "    a-long-local-path-that-must-remain-readable-in-the-error-dialog.txt\n" ** 40 ++
        "Aborting\n";
    app.pages.changes.search.query = app.pages.changes.search.input;
    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    defer ctx.runtimeClearPendingEffectCopies();
    try app.update(.{ .action_finished = .{ .switch_branch = .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .{ .failed = try allocator.dupe(u8, details) },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.overlay.isRemoteError());
    try std.testing.expect(!app.remote_workflow.branch_switch.hasState());
    try std.testing.expectEqual(app_state.GitErrorOperation.switch_branch, app.remote_workflow.remote_error_operation.?);
    try std.testing.expectEqualStrings(details, app.remote_workflow.remote_error_message.?);
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.staged_hunks.items.items.len);
    try std.testing.expectEqualStrings("needle", app.pages.changes.search.query.slice());
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    try app.update(.copy_popup, &ctx);
    try std.testing.expectEqualStrings(details, ctx._pending_clipboard_copies[0].text);

    const close = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.enter } }) orelse return error.ExpectedCloseError;
    try app.update(close, &ctx);
    try std.testing.expect(!app.overlay.isRemoteError());
    try std.testing.expect(app.remote_workflow.remote_error_message == null);
    try std.testing.expectEqual(page.Id.changes, app.active_page);

    // Simulate the branch refresh; file status may still be pending when b reopens.
    clearPendingStatusAndDiffTasks(&ctx, allocator);
    var branch = try branchStatusBundleForRemoteRootTest(allocator, "abc123", "main", "origin/main");
    try app.pages.changes.branch_status.replace(roots.a, &branch);
    _ = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .fresh, .pending, .fresh);
    const reopen = app.handleEvent(.{ .key_press = .{ .codepoint = 'b' } }) orelse return error.ExpectedReopenPicker;
    try app.update(reopen, &ctx);
    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
}

test "finishSwitchBranch success clears completed repo marks when active repo changed" {
    const allocator = std.testing.allocator;
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "old", .display_path = "/repo", .canonical_root = "/repo" },
        .{ .label = "new", .display_path = "/other", .canonical_root = "/other" },
    };
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .workspace = .{
                .current_root = "/workspace",
                .repos = &repos,
            } }, .active_index = 1 },
        },
    };
    defer app.pages.changes.reviewed_store.deinit(allocator);
    defer app.pages.changes.staged_hunks.deinit(allocator);

    try app.pages.changes.reviewed_store.set(allocator, "/repo", app_test_support.files_two[0], true);
    try app.pages.changes.reviewed_store.set(allocator, "/other", app_test_support.files_two[1], true);
    const old_key = testSessionHunkMarkKey(1, 0);
    const new_key = testSessionHunkMarkKey(1, 1);
    try app.pages.changes.staged_hunks.addExact(allocator, "/repo", "a", old_key);
    try app.pages.changes.staged_hunks.addExact(allocator, "/other", "b", new_key);

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.update(.{ .action_finished = .{ .switch_branch = .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(!try app.pages.changes.reviewed_store.containsFile(allocator, "/repo", app_test_support.files_two[0]));
    try std.testing.expect(try app.pages.changes.reviewed_store.containsFile(allocator, "/other", app_test_support.files_two[1]));
    try std.testing.expect(!app.pages.changes.staged_hunks.containsExact("/repo", "a", old_key));
    try std.testing.expect(app.pages.changes.staged_hunks.containsExact("/other", "b", new_key));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
}

test "finishPush does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .push);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .action_finished = .{ .push = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = 0,
            .root_identity = .{ .device = 0, .inode = 0 },
            .operation_generation = pending.generation,
        },
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .outcome = .{ .ok = .completed } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
}

test "finishPull does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .action_finished = .{ .pull = .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .outcome = .{ .ok = .completed } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
}

test "finishPull reloads matching active repo after up-to-date success" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(std.testing.allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    _ = activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.update(.{ .action_finished = .{ .pull = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .repo_root = try std.testing.allocator.dupe(u8, roots.a),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .outcome = .{ .ok = .already_up_to_date } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending != null);
    try std.testing.expectEqualStrings("already up to date", app.pages.changes.status.text());
}

test "finishPull reloads matching active repo after failure" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(std.testing.allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    _ = activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.update(.{ .action_finished = .{ .pull = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .repo_root = try std.testing.allocator.dupe(u8, roots.a),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .outcome = .{ .failed = .failed } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending != null);
    try std.testing.expectEqualStrings("pull failed: remote operation failed; retry in an external terminal", app.pages.changes.status.text());
    try std.testing.expect(!app.overlay.isRemoteError());
}

test "classified pull authentication failures open copyable sanitized details" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]git_remote.RemoteFailure{ .ssh_public_key, .authentication_required }) |failure| {
        var app: App = .{
            .allocator = allocator,
            .repo_session = .{
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
        };
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer remoteWorkflow(&app).clearRemoteError(allocator);
        defer app.shell_effects_state.clipboard_copies.deinit(allocator);
        _ = activateChanges(&app);
        const pending = beginAcceptedTestAction(&app, .pull);
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);
        defer ctx.runtimeClearPendingEffectCopies();

        try app.update(.{ .action_finished = .{ .pull = .{
            .pending = pending,
            .identity = .{
                .repo_epoch = app.repo_session.view().epoch(),
                .root_identity = app.repo_session.view().activeIdentity().?,
                .operation_generation = pending.generation,
            },
            .repo_root = try allocator.dupe(u8, roots.a),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
            .result = .{ .outcome = .{ .failed = failure } },
        } } }, &ctx);

        try std.testing.expect(app.overlay.isRemoteError());
        try std.testing.expectEqual(app_state.GitErrorOperation.pull, app.remote_workflow.remote_error_operation.?);
        const details = app.remote_workflow.remote_error_message.?;
        switch (failure) {
            .ssh_public_key => {
                try std.testing.expectEqualStrings(
                    "pull failed: SSH public-key authentication failed; check ssh-agent and repository access",
                    app.pages.changes.status.text(),
                );
                for ([_][]const u8{
                    "ssh-add -l",
                    "Public-key registration on the Git hosting service",
                    "Your account's access to the repository",
                    "The host/key settings in ~/.ssh/config",
                }) |expected| try std.testing.expect(std.mem.indexOf(u8, details, expected) != null);
                try std.testing.expect(app_view.remoteErrorMaxScroll(.{ .width = 120, .height = 24 }, details) > 0);
            },
            .authentication_required => {
                try std.testing.expectEqualStrings(
                    "pull failed: authentication is required; configure a credential helper or retry in an external terminal",
                    app.pages.changes.status.text(),
                );
                try std.testing.expect(std.mem.indexOf(u8, details, "Authentication is required for pull.") != null);
                try std.testing.expect(std.mem.indexOf(u8, details, "Configure a credential helper") != null);
                try std.testing.expect(std.mem.indexOf(u8, details, "external") != null);
            },
            else => unreachable,
        }

        try app.update(.copy_popup, &ctx);
        try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
        try std.testing.expectEqualStrings(details, ctx._pending_clipboard_copies[0].text);
        for ([_][]const u8{
            "Authorization: Bearer RAW-AUTH-CANARY",
            "password=RAW-PASSWORD-CANARY",
            "RAW-SSH-CANARY",
        }) |canary| {
            try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), canary) == null);
            try std.testing.expect(std.mem.indexOf(u8, details, canary) == null);
            try std.testing.expect(std.mem.indexOf(u8, ctx._pending_clipboard_copies[0].text, canary) == null);
        }
    }
}

test "sensitive diagnostic typed push failure publishes only fixed status overlay and clipboard text" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer remoteWorkflow(&app).clearRemoteError(allocator);
    defer app.shell_effects_state.clipboard_copies.deinit(allocator);
    _ = activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.action_control.begin(pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.{ .action_finished = .{ .push = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, roots.a),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
        .result = .{
            .outcome = .{ .failed = .ssh_public_key },
        },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(!app.remote_workflow.action_control.isActive(pending.generation));
    try std.testing.expect(app.overlay.isRemoteError());
    try std.testing.expectEqualStrings(
        "push failed: SSH public-key authentication failed; check ssh-agent and repository access",
        app.pages.changes.status.text(),
    );
    const detail_message = app.remote_workflow.remote_error_message.?;
    for ([_][]const u8{
        "SSH public-key authentication failed.",
        "ssh-add -l",
        "If ssh-agent cannot be reached",
        "ssh-add <path-to-your-key>",
        "Example: ssh-add ~/.ssh/id_ed25519",
        "for example, ~/.ssh/id_rsa",
        "Public-key registration on the Git hosting service",
        "Your account's access to the repository",
        "The host/key settings in ~/.ssh/config",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, detail_message, expected) != null);
    }
    try std.testing.expect(app_view.remoteErrorMaxScroll(.{ .width = 120, .height = 24 }, detail_message) > 0);

    try app.update(.copy_popup, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings(detail_message, ctx._pending_clipboard_copies[0].text);

    const canaries = [_][]const u8{
        "https://alice:RAW-URL-CANARY@example.invalid/repo.git",
        "Authorization: Bearer RAW-AUTH-CANARY",
        "password=RAW-PASSWORD-CANARY",
        "RAW-ARBITRARY-CANARY",
    };
    for (canaries) |canary| {
        try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), canary) == null);
        try std.testing.expect(std.mem.indexOf(u8, app.remote_workflow.remote_error_message.?, canary) == null);
        try std.testing.expect(std.mem.indexOf(u8, ctx._pending_clipboard_copies[0].text, canary) == null);
    }
}

test "finishFetch does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .fetch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .action_finished = .{ .fetch = .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .{ .outcome = .{ .ok = .completed } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
}

test "finishFetch reloads matching active repo after failure" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(std.testing.allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    _ = activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .fetch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.update(.{ .action_finished = .{ .fetch = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .repo_root = try std.testing.allocator.dupe(u8, roots.a),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .{ .outcome = .{ .failed = .failed } },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending != null);
    try std.testing.expectEqualStrings("fetch failed: remote operation failed; retry in an external terminal", app.pages.changes.status.text());
}

test "remote cancel defers quit until the exact unknown-outcome terminal" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(std.testing.allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    _ = activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.quit, &ctx);
    try std.testing.expect(!app.teardown_requested);
    try std.testing.expectEqualStrings("canceling...", app.pages.changes.status.text());

    try app.update(.{ .action_finished = .{ .pull = .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .repo_root = try std.testing.allocator.dupe(u8, roots.a),
        .branch = try std.testing.allocator.dupe(u8, "main"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{
            .outcome = .{ .failed = .canceled_outcome_unknown },
            .warnings = .{ .git_plaintext_store = true },
        },
    } } }, &ctx);

    try std.testing.expect(app.teardown_requested);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.load.pending != null);
    try std.testing.expectEqualStrings(
        "pull failed: remote operation canceled; outcome is unknown; repository reload required; warning: credential.helper may store credentials in plaintext",
        app.pages.changes.status.text(),
    );
}

test "repository supersession invalidates an in-flight push inspection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    _ = activateChanges(&app);
    try workflow_remote.testing.setRemoteErrorWithRetry(remoteWorkflow(&app), allocator, .push, "failed", .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity().?,
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, roots.a),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    });
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.update(.run_interactive_push, &ctx);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(app.remote_workflow.remote_error_message == null);
}

test "direct root quit remains allowed while push inspection is running" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer remoteWorkflow(&app).clearRemoteError(allocator);
    try workflow_remote.testing.setRemoteErrorWithRetry(remoteWorkflow(&app), allocator, .push, "failed", .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity().?,
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, roots.a),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    });
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.update(.run_interactive_push, &ctx);
    try app.update(.quit, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push inspection surface blocks page switching until canceled" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer remoteWorkflow(&app).clearRemoteError(allocator);
    try workflow_remote.testing.setRemoteErrorWithRetry(remoteWorkflow(&app), allocator, .push, "failed", .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity().?,
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, roots.a),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    });
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.update(.run_interactive_push, &ctx);
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqualStrings("close remote error before switching pages", app.status.text());
    remoteWorkflow(&app).clearRemoteError(allocator);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);

    app.status.clear();
    app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 41 },
        .origin = .{
            .page_id = .changes,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.changes.activation.next_activation_id,
        },
    };
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqualStrings("finish foreground command before switching pages", app.status.text());
    app.shell_effects_state.editor_foreground = null;

    app.status.clear();
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 42 },
        .pending = .{ .generation = 99, .kind = .push },
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = 1,
        },
        .origin = .{
            .page_id = .changes,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.changes.activation.next_activation_id,
        },
        .root = try app.repo_session.view().activeCapability().?.duplicate(),
        .target = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, roots.a),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
        .warnings = .{},
    } };
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqualStrings("finish foreground command before switching pages", app.status.text());
}

test "inactive Changes accepts push inspection diagnostic without redraw" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);
    var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer remoteWorkflow(&app).clearRemoteError(allocator);
    try workflow_remote.testing.setRemoteErrorWithRetry(remoteWorkflow(&app), allocator, .push, "failed", .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity().?,
        .mode = .set_upstream,
        .repo_root = try allocator.dupe(u8, repo.repo_root),
        .branch = try allocator.dupe(u8, "stale-branch"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, repo.oid),
    });
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.update(.run_interactive_push, &ctx);
    app.active_page = .repository;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("push retry unavailable: branch changed; reload and try again", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "finishPushForeground reloads matching active repo after failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 9 },
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = 1,
        },
        .origin = .{ .page_id = .changes, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.changes.activation.next_activation_id },
        .root = try app.repo_session.view().activeCapability().?.duplicate(),
        .target = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, roots.a),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
        .warnings = .{},
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .action_finished = .{ .push_foreground = .{
        .request_id = .{ .id = 9 },
        .outcome = .{ .exited = 1 },
    } } }, &ctx);

    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("interactive push exited: 1", app.pages.changes.status.text());
}

test "inactive Changes foreground completions retain diagnostics without effects" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.active_page = .repository;
    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 7 },
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .operation_generation = 1,
        },
        .origin = .{ .page_id = .changes, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.changes.activation.next_activation_id },
        .root = try app.repo_session.view().activeCapability().?.duplicate(),
        .target = .{
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity().?,
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, roots.a),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
        .warnings = .{},
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.update(.{ .action_finished = .{ .push_foreground = .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 1 },
    } } }, &ctx);

    const expected_status = try std.fmt.allocPrint(allocator, "interactive push exited for {s}: 1", .{roots.a});
    defer allocator.free(expected_status);
    try std.testing.expectEqualStrings(expected_status, app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 8 },
        .origin = .{
            .page_id = .changes,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.changes.activation.next_activation_id,
        },
    };
    try app.update(.{ .shell_effect_finished = .{ .editor = .{
        .request_id = .{ .id = 8 },
        .outcome = .{ .exited = 0 },
    } } }, &ctx);

    try std.testing.expectEqualStrings("editor closed", app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    // An exact completion from the active Changes instance is the only editor
    // terminal that bridges into the Changes read owner.
    var repos = try TestRepoPair.init();
    defer repos.deinit();
    var active_app = try mutationFenceRepoTestApp(allocator, repos.a);
    defer active_app.pages.changes.deinit(allocator);
    defer active_app.repo_session.repo_state.deinit(allocator);
    active_app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 9 },
        .origin = .{
            .page_id = .changes,
            .repo_epoch = active_app.repo_session.repo_epoch,
            .activation_id = active_app.pages.changes.activation.next_activation_id,
        },
    };
    var active_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&active_ctx, allocator);

    try active_app.update(.{ .shell_effect_finished = .{ .editor = .{
        .request_id = .{ .id = 9 },
        .outcome = .{ .exited = 0 },
    } } }, &active_ctx);

    try std.testing.expect(active_app.shell_effects_state.editor_foreground == null);
    try std.testing.expectEqualStrings("editor closed", active_app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 3), active_ctx._pending_tasks_with_len);
}

test "Repository branch switch terminals reload only their caller without activating Changes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    for ([_]bool{ true, false }) |success| {
        var app: App = .{
            .allocator = allocator,
            .active_page = .repository,
            .terminal_size = .{ .width = 120, .height = 32 },
            .repo_session = .{ .repo_epoch = 4, .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
        };
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.pages.changes.deinit(allocator);
        defer app.remote_workflow.deinit(allocator);
        const root_identity = app.repo_session.view().activeIdentity().?;
        app.pages.repository.activate(4, root_identity);
        const identity: page.RequestIdentity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = app.pages.repository.activation_id };
        app.pages.repository.needs_revalidation = false;
        app.pages.repository.generation = 8;
        app.pages.repository.pending_generation = 8;
        app.pages.repository.pending_document_generation = 17;
        app.pages.repository.branch.needs_revalidation = false;
        app.pages.repository.branch.generation = 7;
        app.pages.repository.branch.pending = .{ .identity = identity, .root_identity = root_identity, .generation = 7 };
        app.pages.changes.status.set("Changes retained", .{});
        setDiffSearchQuery(&app, "needle");
        app.pages.changes.search.query = app.pages.changes.search.input;
        const pending = beginAcceptedTestAction(&app, .switch_branch);
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);
        defer ctx.runtimeClearPendingEffectCopies();

        try app.update(.{ .action_finished = .{ .switch_branch = .{
            .pending = .{ .generation = pending.generation + 1, .kind = .switch_branch },
            .repo_root = try allocator.dupe(u8, roots.a),
            .old_branch = try allocator.dupe(u8, "main"),
            .new_branch = try allocator.dupe(u8, "feature"),
            .result = .{ .failed_static = "wrong token" },
        } } }, &ctx);
        try std.testing.expect(app.action_runtime.view().isAccepted(pending));
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

        try app.update(.{ .action_finished = .{ .switch_branch = .{
            .pending = pending,
            .repo_root = try allocator.dupe(u8, roots.a),
            .old_branch = try allocator.dupe(u8, "main"),
            .new_branch = try allocator.dupe(u8, "feature"),
            .result = if (success) .ok else .{ .failed_static = "checkout refused; local changes retained" },
        } } }, &ctx);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(app.remote_workflow.branch_switch_pending == null);
        try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
        try std.testing.expect(app.pages.changes.activation.currentIdentity() == null);
        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expectEqualStrings("Changes retained", app.pages.changes.status.text());
        try std.testing.expectEqualStrings("needle", app.pages.changes.search.query.slice());
        try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
        try std.testing.expectEqual(@as(?u64, 9), app.pages.repository.pending_generation);
        try std.testing.expectEqual(@as(u64, 8), app.pages.repository.branch.pending.?.generation);
        try std.testing.expect(app.pages.repository.pending_document_generation == null);
        if (!success) {
            try std.testing.expectEqual(page.Id.repository, app.overlay.owner_page.?);
            try std.testing.expectEqualStrings("checkout refused; local changes retained", app.remote_workflow.remote_error_message.?);
        }
        // Neither pre-checkout member may publish after the caller reload.
        try app.update(.{ .repository = .{ .manifest_finished = .{
            .identity = identity,
            .root_identity = root_identity,
            .generation = 8,
            .result = .{ .failed_static = "old manifest failure" },
        } } }, &ctx);
        try app.update(.{ .repository = .{ .branch_finished = .{
            .identity = identity,
            .root_identity = root_identity,
            .generation = 7,
            .result = .{ .failed = .load_failed },
        } } }, &ctx);
        try std.testing.expectEqual(@as(?u64, 9), app.pages.repository.pending_generation);
        try std.testing.expectEqual(@as(u64, 8), app.pages.repository.branch.pending.?.generation);
        try std.testing.expect(app.pages.repository.branch.freshness == .validating);
        if (!success) try std.testing.expect(app.overlay.isRemoteError());
    }
}

test "worktree completion uses repository replacement from every branch picker caller" {
    const allocator = std.testing.allocator;
    const git_history = @import("../../git/history.zig");
    const oid = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var destination = try repo_root_capability.RootCapability.openCanonical(roots.b);
    defer destination.deinit();
    for ([_]page.Id{ .changes, .repository, .history, .compare }) |caller| {
        var app: App = .{
            .allocator = allocator,
            .active_page = caller,
            .terminal_size = .{ .width = 120, .height = 32 },
            .repo_session = .{ .repo_epoch = 4, .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
        };
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        defer app.repo_session.deinit(allocator);
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.pages.history.deinit(allocator);
        defer app.pages.compare.deinit(allocator);
        defer app.remote_workflow.deinit(allocator);
        const source_identity = app.repo_session.view().activeIdentity().?;
        _ = activateChanges(&app);
        app.pages.repository.activate(4, source_identity);
        app.pages.history.activate(allocator, 4, source_identity);
        _ = app.pages.compare.activate(4);
        app.pages.history.accepted = .{
            .request = .{
                .snapshot_head = oid,
                .intent = .{ .single = .{ .index = 0, .oid = oid } },
                .basis = .{ .object_format = .sha1, .before = .{ .commit = oid }, .after = oid },
            },
            .origin = .{ .branch = try allocator.dupe(u8, "main") },
            .selected_parent_count = 1,
        };
        app.pages.history.current_view = .diff;
        app.pages.compare.base_target = .{
            .full_ref = try allocator.dupe(u8, "refs/heads/old-base"),
            .display_name = try allocator.dupe(u8, "old-base"),
            .kind = .local,
        };
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);
        defer ctx.runtimeClearPendingEffectCopies();
        try app.update(.request_branch_switch, &ctx);
        clearPendingStatusAndDiffTasks(&ctx, allocator);
        const owner = app.remote_workflow.branch_switch.owner.?;
        try std.testing.expectEqual(caller, owner.origin.page_id);
        app.remote_workflow.branch_switch.loading = false;
        app.remote_workflow.branch_switch.worktree_pending = true;
        try app.update(.{ .load_finished = .{ .shell = .{ .worktree_switch = .{
            .owner = owner,
            .generation = app.remote_workflow.branch_switch.generation,
            .result = .{ .ready = .{
                .discovery = try testSingleRepoDiscovery(allocator, roots.b),
                .root_identity = destination.identity,
            } },
        } } } }, &ctx);
        try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
        try std.testing.expectEqual(@as(u64, 5), app.repo_session.view().epoch());
        try std.testing.expectEqual(caller, app.active_page);
        try std.testing.expect(!app.overlay.isSwitchBranch());
        try std.testing.expect(app.pages.history.accepted == null);
        try std.testing.expect(app.pages.history.current_view == .picker);
        try std.testing.expect(app.pages.compare.base_target == null);
        try std.testing.expectEqualStrings(roots.b, app.repo_session.recent_repos.entries.items[0].path);
        // Read failure after commitment stays at the destination.
        for (ctx.takePendingTasksWith()) |entry| {
            try app.update(entry.failed(entry.ctx, .runtime_abandoned, allocator), &ctx);
        }
        try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
        try std.testing.expectEqual(caller, app.active_page);
    }
}

test "worktree precommit rejections keep caller page diagnostics out of shell status" {
    const allocator = std.testing.allocator;
    const git_history = @import("../../git/history.zig");
    const oid = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const Failure = enum { busy, missing, replaced };
    for ([_]Failure{ .busy, .missing, .replaced }) |failure| {
        var roots = try TestRepoPair.init();
        defer roots.deinit();
        var target = try repo_root_capability.RootCapability.openCanonical(roots.b);
        defer target.deinit();
        var app: App = .{
            .allocator = allocator,
            .active_page = .history,
            .repo_session = .{ .repo_epoch = 4, .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
        };
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        defer app.repo_session.deinit(allocator);
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.pages.history.deinit(allocator);
        defer app.pages.compare.deinit(allocator);
        defer app.remote_workflow.deinit(allocator);
        const source_identity = app.repo_session.view().activeIdentity().?;
        const history = &app.pages.history;
        history.activate(allocator, 4, source_identity);
        history.needs_initial = false;
        history.load_state = .loaded;
        history.accepted = .{
            .request = .{
                .snapshot_head = oid,
                .intent = .{ .single = .{ .index = 0, .oid = oid } },
                .basis = .{ .object_format = .sha1, .before = .{ .commit = oid }, .after = oid },
            },
            .origin = .{ .branch = try allocator.dupe(u8, "main") },
            .selected_parent_count = 1,
        };
        history.current_view = .diff;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingStatusAndDiffTasks(&ctx, allocator);
        defer ctx.runtimeClearPendingEffectCopies();
        try app.update(.request_branch_switch, &ctx);
        clearPendingStatusAndDiffTasks(&ctx, allocator);
        const owner = app.remote_workflow.branch_switch.owner.?;
        app.remote_workflow.branch_switch.loading = false;
        app.remote_workflow.branch_switch.worktree_pending = true;
        if (failure == .busy) {
            _ = beginAcceptedTestAction(&app, .stage_file);
        } else {
            try roots.tmp.dir.rename("b", roots.tmp.dir, "old-b", std.testing.io);
            if (failure == .replaced) try roots.tmp.dir.createDir(std.testing.io, "b", .default_dir);
        }
        try app.update(.{ .load_finished = .{ .shell = .{ .worktree_switch = .{
            .owner = owner,
            .generation = app.remote_workflow.branch_switch.generation,
            .result = .{ .ready = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.b), .root_identity = target.identity } },
        } } } }, &ctx);
        try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);
        try std.testing.expect(source_identity.eql(app.repo_session.view().activeIdentity().?));
        try std.testing.expectEqual(@as(u64, 4), app.repo_session.view().epoch());
        try std.testing.expectEqual(page.Id.history, app.active_page);
        try std.testing.expect(history.current_view == .diff);
        try std.testing.expect(history.accepted.?.request.basis.after.eql(&oid));
        try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
        try std.testing.expect(!app.overlay.isSwitchBranch());
        try std.testing.expect(app.remote_workflow.branch_switch_pending == null);
        try std.testing.expectEqualStrings("", app.status.text());
        const reason = switch (failure) {
            .busy => "finish current git action",
            .missing => "could not be opened safely",
            .replaced => "target worktree changed",
        };
        try std.testing.expect(std.mem.indexOf(u8, history.status.text(), reason) != null);
        try std.testing.expectEqual(app_state.VisibleStatusSource.page, app_state.resolveVisibleStatus(&app.status, &history.status).?.source);
    }
}

test "History and Compare branch switch terminals keep caller intent and retire old reads" {
    const allocator = std.testing.allocator;
    const git_history = @import("../../git/history.zig");
    const history_page = @import("../pages/history.zig");
    const before = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const selected = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const new_head = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const patch = "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n";
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    for ([_]page.Id{ .history, .compare }) |owner| {
        for ([_]bool{ true, false }) |success| {
            var app: App = .{
                .allocator = allocator,
                .active_page = owner,
                .terminal_size = .{ .width = 120, .height = 32 },
                .repo_session = .{ .repo_epoch = 4, .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
            };
            app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
            defer app.repo_session.deinit(allocator);
            defer app.pages.history.deinit(allocator);
            defer app.pages.compare.deinit(allocator);
            defer app.pages.changes.deinit(allocator);
            defer app.remote_workflow.deinit(allocator);
            const root_identity = app.repo_session.view().activeIdentity().?;
            const history = &app.pages.history;
            const compare = &app.pages.compare;
            if (owner == .history) {
                history.activate(allocator, 4, root_identity);
                history.needs_initial = false;
                history.load_state = .loaded;
                history.accepted = .{
                    .request = .{
                        .snapshot_head = selected,
                        .intent = .{ .single = .{ .index = 0, .oid = selected } },
                        .basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = selected },
                    },
                    .origin = .{ .branch = try allocator.dupe(u8, "main") },
                    .selected_parent_count = 1,
                };
                history.current_view = .diff;
                var bundle: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) };
                defer bundle.deinit();
                try history.diff.replaceDiffWithIdentity(allocator, 4, roots.a, root_identity, history_page.selection_source, history.currentPresentationIdentity().?, true, .none, &bundle);
                _ = history.activation.finishMember(history.activation.currentIdentity().?, .source, .immutable);
            } else {
                _ = compare.activate(4);
                const first = compare.beginRefresh().?;
                var loaded = try branchCompareFinished(allocator, first.identity, first.generation, before, selected, patch);
                defer loaded.deinit(allocator);
                _ = try compare.applyLoadFinished(allocator, 4, roots.a, root_identity, &loaded);
            }
            var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
            defer clearPendingStatusAndDiffTasks(&ctx, allocator);
            defer ctx.runtimeClearPendingEffectCopies();
            // The real root request captures these pages without a Changes activation.
            try app.update(.request_branch_switch, &ctx);
            try std.testing.expectEqual(owner, app.overlay.owner_page.?);
            try std.testing.expectEqual(owner, app.remote_workflow.branch_switch.owner.?.origin.page_id);
            try app.update(.cancel_branch_switch, &ctx);
            clearPendingStatusAndDiffTasks(&ctx, allocator);

            const diff = if (owner == .history) &history.diff else &compare.diff;
            diff.viewer.selected_target = .{ .diff_file = 0 };
            diff.viewer.diff_cursor = .{ .hunk_header = 0 };
            diff.viewer.diff_scroll = 2;
            const old_identity = if (owner == .history) history.activation.currentIdentity().? else compare.activation.currentIdentity().?;
            if (owner == .history) {
                history.armDiff(.{ .identity = old_identity, .root_identity = root_identity, .generation = 10, .request = history.accepted.?.request });
            } else {
                compare.refresh_generation = 10;
                compare.replaceDeferredLoad(allocator, try branchCompareFinished(allocator, old_identity, 10, before, selected, patch));
            }
            const pending = beginAcceptedTestAction(&app, .switch_branch);
            diff.selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "file.txt" } },
                .content = .{ .source_side = .{ .side = .new } },
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 0 },
                .moved = true,
            } };
            try app.update(.{ .action_finished = .{ .switch_branch = .{
                .pending = pending,
                .repo_root = try allocator.dupe(u8, roots.a),
                .old_branch = try allocator.dupe(u8, "main"),
                .new_branch = try allocator.dupe(u8, "feature"),
                .result = if (success) .ok else .{ .failed_static = "checkout refused" },
            } } }, &ctx);
            try std.testing.expectEqual(owner, app.active_page);
            try std.testing.expect(app.pages.changes.activation.currentIdentity() == null);
            try std.testing.expect(!app.action_runtime.view().hasPending());
            try std.testing.expect(diff.selection_owner == .none);
            if (!success) {
                try std.testing.expectEqual(owner, app.overlay.owner_page.?);
                try std.testing.expectEqualStrings("checkout refused", app.remote_workflow.remote_error_message.?);
            }
            if (owner == .history) {
                try std.testing.expectEqual(history_page.CurrentView.diff, history.current_view);
                try std.testing.expect(history.activation.state.satisfiesAction(.read_diff));
                try std.testing.expect(history.accepted.?.request.basis.after.eql(&selected));
                try std.testing.expect(history.accepted.?.request.basis.before.commit.eql(&before));
                try std.testing.expectEqual(@as(usize, 2), diff.viewer.diff_scroll);
                try std.testing.expectEqual(@as(usize, 0), diff.viewer.diff_cursor.hunk_header);
                const probe = history.pending.?.catalog;
                try std.testing.expectEqual(if (success) app_load.HistoryProbeReason.reload else .activation, probe.request.probe);
                try app.update(.{ .load_finished = .{ .history = .{ .diff = .{
                    .identity = old_identity,
                    .root_identity = root_identity,
                    .generation = 10,
                    .request = history.accepted.?.request,
                    .result = .{ .failed_static = "old diff" },
                } } } }, &ctx);
                try std.testing.expectEqual(probe.generation, history.pending.?.catalog.generation);
                try app.update(.{ .load_finished = .{ .history = .{ .catalog = .{
                    .identity = probe.identity,
                    .root_identity = root_identity,
                    .generation = probe.generation,
                    .request = probe.request,
                    .result = .{ .loaded = .{ .snapshot = .{ .object_format = .sha1, .head = new_head, .display = .{ .branch = try allocator.dupe(u8, "feature") } } } },
                } } } }, &ctx);
                try std.testing.expect(history.currentHeadContext().?.head.?.eql(&new_head));
                try std.testing.expect(history.accepted.?.request.basis.after.eql(&selected));
                try std.testing.expectEqual(history_page.CurrentView.diff, history.current_view);
            } else {
                try std.testing.expect(compare.deferred_load_apply == null);
                try std.testing.expectEqualStrings("refs/heads/main", compare.base_target.?.full_ref);
                try std.testing.expect(compare.refresh_generation > 10);
                try std.testing.expect(compare.diff.reload_anchor != null);
                const generation = compare.refresh_generation;
                try app.update(.{ .load_finished = .{ .compare = .{ .source = try branchCompareFinished(allocator, old_identity, 10, before, selected, patch) } } }, &ctx);
                try std.testing.expectEqual(generation, compare.refresh_generation);
                try app.update(.{ .load_finished = .{ .compare = .{ .source = try branchCompareFinished(allocator, old_identity, generation, before, new_head, patch) } } }, &ctx);
                try std.testing.expect(compare.basis.?.target.head_oid.eql(&new_head));
                try std.testing.expectEqualStrings("refs/heads/main", compare.base_target.?.full_ref);
                try std.testing.expect(compare.diff.reload_anchor == null);
            }
            if (!success) try std.testing.expect(app.overlay.isRemoteError());
        }
    }
}

fn branchCompareFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base: @import("../../git/history.zig").ObjectId,
    head: @import("../../git/history.zig").ObjectId,
    patch: []const u8,
) !app_load.CompareLoadFinished {
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{ .full_ref = try allocator.dupe(u8, "refs/heads/main"), .display_name = try allocator.dupe(u8, "main"), .kind = .local },
                .head_display = try allocator.dupe(u8, "feature"),
                .target = .{ .object_format = .sha1, .base_oid = base, .head_oid = head, .diff_base_oid = base },
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, patch) },
        } },
    };
}
