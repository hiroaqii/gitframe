//! Root integration tests for Changes read coordination and canonical publication.

const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_auto_reload = @import("../auto_reload.zig");
const app_load_state = @import("../load_state.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_projection_component = @import("../projection_component.zig");
const app_changes_projection = @import("../changes_projection.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const page = @import("../page.zig");
const repo_session = @import("../repo_session.zig");
const changes_page = @import("../pages/changes.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const content_selection = @import("../diff_surface/selection.zig");
const context = @import("../../context.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_file = @import("../../diff/file.zig");
const diff_hunk_projection = @import("../../diff/hunk_projection.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_presentation_identity = @import("../../diff/presentation_identity.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_status = @import("../../git/status.zig");
const git_ops = @import("../git_ops.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");

const App = app_mod.App;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const ChangesProjectionTask = app_load.ChangesProjectionTask(app_message.Msg);
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(app_message.Msg);
const LoadedDiff = loaded_diff.LoadedDiff;
const ToggleStageOperation = git_ops.ToggleStageOperation;

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

const reordered_action_refresh_diff =
    \\diff --git a/b b/b
    \\index 1..2 100644
    \\--- a/b
    \\+++ b/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -1 +1 @@
    \\-old a
    \\+new a
    \\
;

fn activateChanges(app: *App) u64 {
    const source_member: changes_authority.MemberFreshness = .pending;
    const auxiliary: changes_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(app.config.source) and
        app.repo_session.view().activeRoot() != null) .pending else .unavailable;
    return app.pages.changes.activation.activate(
        app.repo_session.view().epoch(),
        source_member,
        auxiliary,
        auxiliary,
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

fn changesNavigationView(app: *const App) changes_navigation.View {
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

fn repoSession(app: *App) repo_session.Controller {
    return .{
        .state = &app.repo_session,
        .status = &app.status,
        .active_page = app.active_page,
        .source = app.config.source,
        .home = null,
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    return repoSession(app).commitDiscovered(&ctx.ctx, result, active_index, origin);
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
        app.repo_session.repo_epoch,
        identity,
        kind,
        path_key,
    );
    changesNavigation(app).installActionCursor(allocator, &prepared, action_generation);
}

fn promoteTestActionCursorWithRequirement(
    app: *App,
    action_generation: u64,
    requirement: changes_page.action_cursor.RefreshRequirement,
) !void {
    const owner = app.pages.changes.action_cursor.owner orelse return error.ExpectedActionCursorOwner;
    try std.testing.expect(app.pages.changes.action_cursor.promote(
        action_generation,
        owner.repo_epoch,
        owner.root_identity,
        requirement,
    ));
}

fn promoteTestActionCursor(app: *App, action_generation: u64) !void {
    try promoteTestActionCursorWithRequirement(app, action_generation, .source_and_status);
}

fn syncTestActivation(app: *App) void {
    const source: changes_authority.MemberFreshness = if (app.pages.changes.auto_reload.sourceIsActionable())
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

fn acceptTestSource(app: *App) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn ownTestSourceRead(app: *App, generation: u64, kind: changes_page.ReloadKind) void {
    app.pages.changes.load.generation = generation;
    app.pages.changes.load.pending = .{ .diff_load = generation };
    if (app.pages.changes.pending_reload) |*pending| {
        std.debug.assert(pending.generation == generation);
        pending.read_epoch = app.pages.changes.repository_read_authority.epoch;
    } else {
        app.pages.changes.pending_reload = .{
            .generation = generation,
            .read_epoch = app.pages.changes.repository_read_authority.epoch,
            .kind = kind,
        };
    }
}

fn setDiffSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.pages.changes.search.query.buffer[0..query.len], query);
    app.pages.changes.search.query.len = query.len;
    app.pages.changes.search.query.cursor = query.len;
    setDiffSearchInput(app, query);
}

fn testCombinedHunkBundle(
    allocator: std.mem.Allocator,
) !app_changes_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(
        allocator,
        app_test_support.diff_cached_projection,
    );
    errdefer cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(
        allocator,
        app_test_support.diff_unstaged_projection,
    );
    errdefer unstaged_bundle.deinit();
    var cached_authority = try app_projection_component.ParsedComponent.parse(
        allocator,
        app_test_support.diff_cached_projection,
    );
    errdefer cached_authority.deinit();
    var unstaged_authority = try app_projection_component.ParsedComponent.parse(
        allocator,
        app_test_support.diff_unstaged_projection,
    );
    errdefer unstaged_authority.deinit();
    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer presentation_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    return .{
        .presentation = .{
            .arena = presentation_arena,
            .projection = projection.presentation,
            .cached_bundle = cached_bundle,
            .unstaged_bundle = unstaged_bundle,
            .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
            .content_token = .init(1),
        },
        .authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached_authority,
            .unstaged_component = unstaged_authority,
            .status_snapshot_revision = 0,
        },
    };
}

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?git_branch_status.Upstream = null,
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

fn branchStatusBundleForTest(
    allocator: std.mem.Allocator,
    spec: BranchStatusBundleSpec,
) !git_branch_status.BranchStatusBundle {
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

fn testSingleRepoDiscovery(
    allocator: std.mem.Allocator,
    root: []const u8,
) !repo_discovery.DiscoveryResult {
    return testNamedSingleRepoDiscovery(allocator, std.fs.path.basename(root), root);
}

fn testNamedSingleRepoDiscovery(
    allocator: std.mem.Allocator,
    label: []const u8,
    root: []const u8,
) !repo_discovery.DiscoveryResult {
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

fn requestPageSwitchForTest(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    target: page.Id,
) !void {
    try app.update(.{ .switch_page = target }, ctx);
}

fn publicStageFileTestApp(
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
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
    };
    errdefer app.pages.changes.deinit(allocator);
    errdefer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(repo_root, &status);
    acceptTestSource(&app);
    return app;
}

fn publishPathDiscovery(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    submitted_path: []const u8,
    discovery: repo_discovery.DiscoveryResult,
) !void {
    var owned_discovery: ?repo_discovery.DiscoveryResult = discovery;
    errdefer if (owned_discovery) |*value| value.deinit(allocator);
    var owned_path: ?[]u8 = try allocator.dupe(u8, submitted_path);
    errdefer if (owned_path) |value| allocator.free(value);

    const generation = app.repo_session.repo_picker.beginPathDiscovery();
    const message = App.Msg.loadFinished(.{ .shell = .{ .repo_path_discovery = .{
        .generation = generation,
        .submitted_path = owned_path.?,
        .result = .{ .discovered = owned_discovery.? },
    } } });
    owned_discovery = null;
    owned_path = null;
    try app.update(message, ctx);
}

test "Changes mutation read fence follows accepted action launch and exact terminal" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try publicStageFileTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const epoch_before_launch = app.pages.changes.repository_read_authority.epoch;
    try app.update(.{ .changes = .toggle_selected_file }, &ctx.ctx);
    const pending = app.action_runtime.view().acceptedPending() orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var action_tasks = ctx.takeTask(0).?;
    defer action_tasks.deinit();

    try std.testing.expect(!app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(app.pages.changes.repository_read_authority.epoch.eql(epoch_before_launch.next()));
    try std.testing.expect(app.pages.changes.repository_read_authority.ownsMutation(pending));

    const stale: app_actions.PendingAction = .{
        .generation = pending.generation -% 1,
        .kind = pending.kind,
    };
    try app.update(App.Msg.actionFinished(.{ .stage_file = .{
        .pending = stale,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .result = .{ .failed_static = "stale fixture" },
    } }), &ctx.ctx);
    try std.testing.expect(app.action_runtime.view().isAccepted(pending));
    try std.testing.expect(app.pages.changes.repository_read_authority.ownsMutation(pending));

    const exact = try action_tasks.fail(error.ConcurrencyUnavailable);
    try app.update(exact, &ctx.ctx);

    try std.testing.expect(!app.action_runtime.view().isCurrent(pending));
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(app.pages.changes.repository_read_authority.epoch.eql(epoch_before_launch.next()));
    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
}
test "Changes mutation read fence drains old production reads without publication" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .auto_reload = .init(.enabled, .{}),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.remote_workflow.push_retry.deinit(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(roots.a, &old_status);
    var old_branch = try branchStatusBundleForTest(allocator, .{
        .oid = "old-oid",
        .branch = "old-branch",
    });
    try app.pages.changes.branch_status.replace(roots.a, &old_branch);
    acceptTestSource(&app);
    const identity = app.pages.changes.activation.currentIdentity() orelse
        return error.ExpectedChangesActivation;
    const old_epoch = app.pages.changes.repository_read_authority.epoch;
    const body_ptr = changesNavigationView(&app).activeLoadedDiffConst().?.text.ptr;

    const cycle_id = app.pages.changes.auto_reload.beginCycle() orelse
        return error.ExpectedBackgroundCycle;
    var task_ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    task_ctx.init(allocator, std.testing.io);
    defer task_ctx.deinit();
    app.pages.changes.auto_reload.discardEmptyCycle(cycle_id);
    try app.update(.auto_reload_tick, &task_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 3), task_ctx.pendingTaskCount());
    var queued = [_]chasen.testing.TestTask(App.Msg){ task_ctx.takeTask(0).?, task_ctx.takeTask(0).?, task_ctx.takeTask(0).? };
    defer for (&queued) |*task| task.deinit();

    const root_identity = app.repo_session.view().activeIdentity() orelse
        return error.ExpectedRootIdentity;
    app.pages.changes.changes_projection.installReady(.{
        .request = try app_changes_projection.cloneRequestWithOptions(
            allocator,
            identity,
            31,
            roots.a,
            "old-generated.zig",
            .generated_added_file,
            .unstaged,
            app.pages.changes.source_session_revision,
            app.pages.changes.status_snapshot_revision,
            .{ .read_epoch = old_epoch, .root_identity = root_identity },
        ),
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(
            allocator,
            "old-generated.zig",
            "const old = true;\n",
        ) },
    });
    const displayed_ptr =
        app.pages.changes.changes_projection.displayed.ready.value.generated_added_file.source.bytes.ptr;
    app.pages.changes.changes_projection.syntax_pending =
        try app_changes_projection.generatedSyntaxRequestForProjection(
            allocator,
            41,
            identity,
            app.pages.changes.changes_projection.displayed.ready.request,
            app.pages.changes.changes_projection.displayed.ready.value.generated_added_file.fingerprint(),
        );
    const displayed_fingerprint =
        app.pages.changes.changes_projection.displayed.ready.value.generated_added_file.fingerprint();
    const old_syntax_result_request = try app_changes_projection.cloneGeneratedSyntaxRequest(
        allocator,
        app.pages.changes.changes_projection.syntax_pending.?,
    );
    app.pages.changes.changes_projection.pending =
        try app_changes_projection.cloneRequestWithOptions(
            allocator,
            identity,
            32,
            roots.a,
            "new-generated.zig",
            .generated_added_file,
            .unstaged,
            app.pages.changes.source_session_revision,
            app.pages.changes.status_snapshot_revision,
            .{ .read_epoch = old_epoch, .root_identity = root_identity },
        );
    const old_projection_request = app.pages.changes.changes_projection.pending.?;
    const old_projection_result_request = try app_changes_projection.cloneRequestWithOptions(
        allocator,
        old_projection_request.identity,
        old_projection_request.id,
        old_projection_request.repo_root,
        old_projection_request.path_key,
        old_projection_request.kind,
        old_projection_request.source_kind,
        old_projection_request.source_session_revision,
        old_projection_request.status_snapshot_revision,
        .{
            .read_epoch = old_projection_request.read_epoch,
            .root_identity = old_projection_request.root_identity,
            .expected_presentation = old_projection_request.expected_presentation,
        },
    );

    var status_message = try queued[0].fail(error.ConcurrencyUnavailable);
    status_message.load_finished.changes.status.result = .{ .loaded = try git_status.StatusBundle.parseOwned(allocator, " M new.zig\x00") };
    var branch_message = try queued[1].fail(error.ConcurrencyUnavailable);
    branch_message.load_finished.changes.branch_status.result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .oid = "new-oid", .branch = "new-branch" }) };
    var source_message = try queued[2].fail(error.ConcurrencyUnavailable);
    source_message.load_finished.changes.source.result = .{ .loaded = try app_load.buildLoadedBundle(allocator, app_test_support.diff_unstaged_projection) };

    const pending = beginAcceptedTestAction(&app, .push);
    const action_terminal = App.Msg.actionFinished(.{ .push = .{
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
        .result = .{ .outcome = .{ .ok = .completed } },
    } });

    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    const epoch_advanced =
        app.pages.changes.repository_read_authority.epoch.eql(old_epoch.next());
    const body_retained_at_launch =
        changesNavigationView(&app).activeLoadedDiffConst().?.text.ptr == body_ptr;
    const projection_retired_at_launch =
        app.pages.changes.changes_projection.pending == null;
    const syntax_retired_at_launch =
        app.pages.changes.changes_projection.syntax_pending == null;
    const displayed_retained_at_launch = switch (app.pages.changes.changes_projection.displayed) {
        .ready => |ready| switch (ready.value) {
            .generated_added_file => |generated| generated.source.bytes.ptr == displayed_ptr,
            else => false,
        },
        else => false,
    };
    const cycle_superseded_at_launch =
        app.pages.changes.auto_reload.background_cycle != null and
        app.pages.changes.auto_reload.background_cycle.?.acceptance ==
            .superseded_by_mutation;

    var delivery_ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    delivery_ctx.init(allocator, std.testing.io);
    defer delivery_ctx.deinit();

    try app.update(status_message, &delivery_ctx.ctx);
    try app.update(branch_message, &delivery_ctx.ctx);
    try app.update(source_message, &delivery_ctx.ctx);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = old_projection_result_request,
        .result = .{ .ready = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(
            allocator,
            "new-generated.zig",
            "const replacement = true;\n",
        ) } },
    } } }), &delivery_ctx.ctx);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection_syntax = .{
        .request = old_syntax_result_request,
        .snapshot_fingerprint = displayed_fingerprint,
        .result = .{ .terminal_plain = .provider_unavailable },
    } } }), &delivery_ctx.ctx);

    const displayed_retained_after_terminals = switch (app.pages.changes.changes_projection.displayed) {
        .ready => |ready| switch (ready.value) {
            .generated_added_file => |generated| generated.source.bytes.ptr == displayed_ptr,
            else => false,
        },
        else => false,
    };
    const body_retained_after_terminals =
        changesNavigationView(&app).activeLoadedDiffConst() != null and
        changesNavigationView(&app).activeLoadedDiffConst().?.text.ptr == body_ptr;
    const status_retained_after_terminal =
        app.pages.changes.git_status.document.entries.len == 1 and
        std.mem.eql(
            u8,
            app.pages.changes.git_status.document.entries[0].path,
            "a",
        );
    const branch_retained_after_terminal =
        app.pages.changes.branch_status.status.branchName() != null and
        std.mem.eql(
            u8,
            app.pages.changes.branch_status.status.branchName().?,
            "old-branch",
        );
    const stale_completions_started_no_reads = delivery_ctx.pendingTaskCount() == 0;
    const old_read_owners_retired =
        app.pages.changes.load.pending == null and
        app.pages.changes.status_load.pending == null and
        app.pages.changes.branch_status_load.pending == null and
        app.pages.changes.auto_reload.background_cycle == null;
    try app.update(action_terminal, &delivery_ctx.ctx);
    const exact_terminal = !app.action_runtime.view().isCurrent(pending);
    const fence_reopened =
        app.pages.changes.repository_read_authority.mayStartRepositoryRead();

    try std.testing.expect(fence_closed);
    try std.testing.expect(epoch_advanced);
    try std.testing.expect(body_retained_at_launch);
    try std.testing.expect(projection_retired_at_launch);
    try std.testing.expect(syntax_retired_at_launch);
    try std.testing.expect(displayed_retained_at_launch);
    try std.testing.expect(cycle_superseded_at_launch);
    try std.testing.expect(stale_completions_started_no_reads);
    try std.testing.expect(status_retained_after_terminal);
    try std.testing.expect(branch_retained_after_terminal);
    try std.testing.expect(body_retained_after_terminals);
    try std.testing.expect(displayed_retained_after_terminals);
    try std.testing.expect(old_read_owners_retired);
    try std.testing.expect(exact_terminal);
    try std.testing.expect(fence_reopened);
    try std.testing.expectEqual(@as(usize, 3), delivery_ctx.pendingTaskCount());
}
test "background branch completion during repository action is discarded and releases cycle" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.changes.branch_status.deinit();
    var current = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "old-oid",
        .branch = "old-branch",
    });
    try app.pages.changes.branch_status.replace("/repo", &current);

    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .branch));
    const generation = app.pages.changes.branch_status_load.prepare(true);
    app.pages.changes.branch_status_load.begin(cycle_id, .{});
    _ = beginAcceptedTestAction(&app, .stage_file);
    const changed = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "new-oid",
        .branch = "new-branch",
    });
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = changed },
    } } }), &ctx.ctx);

    try std.testing.expectEqualStrings("old-branch", app.pages.changes.branch_status.status.branchName().?);
    try std.testing.expect(!app.pages.changes.branch_status_load.isPending());
    try std.testing.expectEqual(app_auto_reload.AuxiliaryFreshness.stale_refresh, app.pages.changes.branch_status_load.freshness);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}
test "inactive page timer starts no Changes work" {
    var app: App = .{
        .active_page = .repository,
        .pages = .{ .changes = .{ .auto_reload = .{
            .activation = .automatic,
            .interval_ns = 3 * std.time.ns_per_s,
        } } },
    };
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.auto_reload_tick, &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}
test "mutation read start gate retains manual and queued revalidation until reopen" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
    };
    const activation_id = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 61,
        .kind = .stage_hunk,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.reload, &ctx.ctx);
    try std.testing.expectEqual(
        activation_id,
        app.pages.changes.activation.revalidation_requested orelse return error.ExpectedRevalidationIntent,
    );
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expectEqual(
        activation_id,
        app.pages.changes.activation.revalidation_requested orelse return error.ExpectedRetainedRevalidationIntent,
    );

    try app.update(.reload, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expectEqual(
        activation_id,
        app.pages.changes.activation.revalidation_requested orelse return error.ExpectedCoalescedRevalidationIntent,
    );

    try std.testing.expect(app.pages.changes.repository_read_authority.reopenForMutation(owner));
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.activation.revalidation_requested == null);
    try std.testing.expect(app.pages.changes.load.pending != null);
}
test "mutation read start gate blocks forced auto reload before cycle ownership" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{ .auto_reload = .{
            .activation = .forced,
            .interval_ns = 3 * std.time.ns_per_s,
        } } },
    };
    _ = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 62,
        .kind = .unstage_hunk,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.auto_reload_tick, &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}
test "closed read authority queues action-terminal revalidation instead of dropping" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
    };
    _ = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 71,
        .kind = .stage_file,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    // Model the exact terminal's activation-scoped fallback, then let the
    // public update tail encounter the still-closed read fence.
    app.pages.changes.activation.queueActionTerminalRevalidation();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);

    try std.testing.expect(app.pages.changes.activation.hasQueuedFullRevalidation());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}
test "closed read authority consequence is a typed route policy" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
    };
    _ = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 72,
        .kind = .unstage_file,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.auto_reload_tick, &ctx.ctx);
    try std.testing.expect(!app.pages.changes.activation.hasQueuedFullRevalidation());

    try app.update(.reload, &ctx.ctx);
    try std.testing.expect(app.pages.changes.activation.hasQueuedFullRevalidation());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "closed read authority keeps watch tick drop semantics without queueing" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{ .auto_reload = .{
            .activation = .forced,
            .interval_ns = 3 * std.time.ns_per_s,
        } } },
    };
    _ = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 73,
        .kind = .stage_hunk,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.auto_reload_tick, &ctx.ctx);

    // Copy 5 keeps its drop-and-next-tick semantics: no queued revalidation
    // fires when the authority reopens.
    try std.testing.expect(!app.pages.changes.activation.hasQueuedFullRevalidation());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}
test "mutation read start gate makes direct App read starters inert" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
    };
    _ = activateChanges(&app);
    const owner: app_actions.PendingAction = .{
        .generation = 63,
        .kind = .stage_file,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.reload, &ctx.ctx);
    try app.update(.auto_reload_tick, &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.status_load.pending == null);
    try std.testing.expect(app.pages.changes.branch_status_load.pending == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.status.text().len);
}
test "mutation read promotion gate makes App projection scheduling inert" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{
                .discovery = try testSingleRepoDiscovery(allocator, "/repo"),
            },
        },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
        } },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = activateChanges(&app);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    const owner: app_actions.PendingAction = .{
        .generation = 64,
        .kind = .unstage_file,
    };
    try std.testing.expect(app.pages.changes.repository_read_authority.closeForMutation(owner));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
}
test "Changes re-entry queues one revalidation behind an older read and leaving cancels it" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = .{ .state = .loading, .generation = 1, .pending = .{ .diff_load = 1 } },
        } },
    };
    const first_activation = activateChanges(&app);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try requestPageSwitchForTest(&app, &ctx.ctx, .repository);
    try requestPageSwitchForTest(&app, &ctx.ctx, .changes);
    const second_activation = app.pages.changes.activation.state.active.activation_id;
    try std.testing.expect(first_activation != second_activation);
    try std.testing.expectEqual(@as(?u64, second_activation), app.pages.changes.activation.revalidation_requested);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());

    try requestPageSwitchForTest(&app, &ctx.ctx, .repository);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expect(app.pages.changes.activation.revalidation_requested == null);
}
test "Changes re-entry starts immediate fingerprint revalidation even when polling is disabled" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("GIT_DIR", "/must-be-sanitized-before-branch-read");
    try env.put("ISSUE54_BRANCH_ENV_CANARY", "queue-time-value");

    var app: App = .{
        .active_page = .repository,
        .allocator = allocator,
        .env_map = &env,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .pages = .{ .changes = .{ .load = .{ .state = .{ .empty = .no_changes } } } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("retained"));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try requestPageSwitchForTest(&app, &ctx.ctx, .changes);
    try env.put("ISSUE54_BRANCH_ENV_CANARY", "parent-after-queue");

    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    var entries = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&entries) |*task| task.deinit();
    var status_task_message = try entries[0].fail(error.ConcurrencyUnavailable);
    defer status_task_message.deinitUndelivered(allocator);
    const status_task = status_task_message.load_finished.changes.status;
    var branch_task_message = try entries[1].fail(error.ConcurrencyUnavailable);
    defer branch_task_message.deinitUndelivered(allocator);
    const branch_task = branch_task_message.load_finished.changes.branch_status;
    var diff_task_message = try entries[2].fail(error.ConcurrencyUnavailable);
    defer diff_task_message.deinitUndelivered(allocator);
    const diff_task = diff_task_message.load_finished.changes.source;
    const active = app.pages.changes.activation.state.active;
    try std.testing.expectEqual(active.activation_id, status_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, branch_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, diff_task.identity.activation_id);
    try std.testing.expectEqualStrings(
        "/must-be-sanitized-before-branch-read",
        env.get("GIT_DIR").?,
    );
    try std.testing.expectEqualStrings(
        "parent-after-queue",
        env.get("ISSUE54_BRANCH_ENV_CANARY").?,
    );
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source != null);
}
test "repo picker capability rejection preserves Changes navigation and does not reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    try roots.tmp.dir.symLink(io, "b", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(roots.a).?, "linked" });
    defer allocator.free(linked);

    var app: App = .{
        .allocator = allocator,
        .repo_session = .{ .repo_picker = .{ .mode = true } },
    };
    defer app.repo_session.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    defer if (app.remote_workflow.branch_switch.hasState()) app.remote_workflow.branch_switch.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    const prior_epoch = app.repo_session.view().epoch();
    const prior_identity = app.repo_session.view().activeIdentity().?;
    app.pages.changes.viewer.selected_target = .{ .diff_file = 3 };
    app.pages.changes.viewer.selected_node = 7;
    app.pages.changes.search.mode = true;
    app.pages.repository.load_state = .loaded;
    app.pages.repository.freshness = .fresh;
    try installTestActionCursor(&app, allocator, .file, "src/app.zig", 9);
    app.pages.changes.pending_reload = .{ .generation = 31, .kind = .manual };
    app.remote_workflow.branch_switch = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .generation = 12,
        .loading = true,
    };
    app.remote_workflow.branch_switch_load_pending = 12;
    app.overlay.openSwitchBranch(.changes);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const generation = app.repo_session.repo_picker.beginPathDiscovery();

    try app.update(App.Msg.loadFinished(.{ .shell = .{ .repo_path_discovery = .{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, linked),
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, linked) },
    } } }), &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expectEqual(prior_epoch, app.repo_session.view().epoch());
    try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);
    try std.testing.expect(prior_identity.eql(app.repo_session.view().activeIdentity().?));
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 3 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 7), app.pages.changes.viewer.selected_node);
    try std.testing.expect(app.pages.changes.search.mode);
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u64, 31), app.pages.changes.pending_reload.?.generation);
    try std.testing.expect(app.remote_workflow.branch_switch.hasState());
    try std.testing.expectEqual(@as(?u64, 12), app.remote_workflow.branch_switch_load_pending);
    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.pages.repository.load_state == .loaded);
    try std.testing.expect(app.pages.repository.freshness == .fresh);
    try std.testing.expectEqualStrings("Repository root could not be opened safely", app.status.text());
}
test "committed repository replacement resets Changes before source spawn failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .allocator = allocator, .active_page = .repository };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        try testSingleRepoDiscovery(allocator, roots.a),
    );
    app.active_page = .changes;
    _ = activateChanges(&app);
    app.pages.changes.viewer.selected_target = .{ .diff_file = 3 };
    app.pages.changes.viewer.selected_node = 7;
    app.pages.changes.search.mode = true;
    setDiffSearchQuery(&app, "needle");

    try ctx.fillTaskSlots(16);
    try std.testing.expectError(error.TaskLimitExceeded, publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.b,
        try testSingleRepoDiscovery(allocator, roots.b),
    ));
    ctx.discardPendingTasks();

    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(!app.pages.changes.search.mode);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.search.input.len);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.search.query.len);
}
test "repo discovery remains owned when recent-store update fails" {
    const backing = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .active_page = .repository };
    const activation_id = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    const generation = app.pages.changes.load.beginRepoDiscovery();
    app.pages.changes.load.state = .loading;
    const discovery = try testSingleRepoDiscovery(backing, roots.a);

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.repo_session.recent_repos.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try std.testing.expectError(error.OutOfMemory, app.update(App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(0, activation_id),
        .generation = generation,
        .result = .{ .discovered = discovery },
    } } }), &ctx.ctx));

    try std.testing.expect(app.repo_session.repo_state.discovery == null);
    try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.pages.changes.load.state == .idle);
    try std.testing.expectEqual(changes_authority.MemberFreshness.failed, app.pages.changes.activation.state.members().?.source);
}
test "repo discovery completion cannot overwrite a newer repository commitment" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .active_page = .repository };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const first_activation = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    const first_generation = app.pages.changes.load.beginRepoDiscovery();
    try app.update(App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(0, first_activation),
        .generation = first_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    } } }), &ctx.ctx);
    try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 1), app.repo_session.repo_epoch);

    try app.update(.enter_repo_picker, &ctx.ctx);
    try app.update(.repo_picker_enter_filter_input, &ctx.ctx);
    try app.update(.{ .repo_picker_insert = 'a' }, &ctx.ctx);
    const picker_focus = app.repo_session.repo_picker.list.filter.list.focusedIndex();

    const same_activation = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .pending, .pending, .pending);
    const same_generation = app.pages.changes.load.beginRepoDiscovery();
    try app.update(App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(1, same_activation),
        .generation = same_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    } } }), &ctx.ctx);
    try std.testing.expectEqual(@as(u64, 1), app.repo_session.repo_epoch);
    try std.testing.expect(app.repo_session.repo_picker.mode);
    try std.testing.expect(app.repo_session.repo_picker.input_mode == .filter);
    try std.testing.expectEqualStrings("a", app.repo_session.repo_picker.list.input.slice());
    try std.testing.expectEqual(picker_focus, app.repo_session.repo_picker.list.filter.list.focusedIndex());

    const same_epoch_stale_activation = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .pending, .pending, .pending);
    const same_epoch_stale_generation = app.pages.changes.load.beginRepoDiscovery();
    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        try testNamedSingleRepoDiscovery(allocator, "fresh selection", roots.a),
    );
    try std.testing.expect(!app.pages.changes.load.hasPending());
    try app.update(App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(1, same_epoch_stale_activation),
        .generation = same_epoch_stale_generation,
        .result = .{ .discovered = try testNamedSingleRepoDiscovery(allocator, "stale completion", roots.a) },
    } } }), &ctx.ctx);
    const committed = app.repo_session.repo_state.discovery orelse return error.ExpectedSingleRepository;
    switch (committed) {
        .single_repo => |entry| try std.testing.expectEqualStrings("fresh selection", entry.label),
        else => return error.ExpectedSingleRepository,
    }
    try std.testing.expectEqual(@as(u64, 1), app.repo_session.repo_epoch);

    const stale_activation = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .pending, .pending, .pending);
    const stale_generation = app.pages.changes.load.beginRepoDiscovery();
    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.b,
        try testSingleRepoDiscovery(allocator, roots.b),
    );
    try std.testing.expectEqual(@as(u64, 2), app.repo_session.repo_epoch);
    try std.testing.expect(!app.pages.changes.load.hasPending());

    try app.update(App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(1, stale_activation),
        .generation = stale_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    } } }), &ctx.ctx);
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.repo_session.repo_epoch);

    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        try testSingleRepoDiscovery(allocator, roots.a),
    );
    try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 3), app.repo_session.repo_epoch);
}
test "inactive repository change invalidates retained source before equal-fingerprint re-entry" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .active_page = .repository, .allocator = allocator };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        try testSingleRepoDiscovery(allocator, roots.a),
    );

    var retained = app_test_support.loadedDiffOne();
    retained.text = app_test_support.diff_one;
    app.pages.changes.load = app_test_support.loadState(retained);
    const shared_fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    app.pages.changes.auto_reload.acceptSource(shared_fingerprint);

    const source_revision = app.pages.changes.source_session_revision;
    const status_revision = app.pages.changes.status_snapshot_revision;
    app.pages.changes.changes_projection.installReady(.{
        .request = try app_changes_projection.testing.cloneRequest(
            allocator,
            page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
            1,
            roots.a,
            "cached-a",
            .generated_added_file,
            .unstaged,
            source_revision,
            status_revision,
        ),
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(allocator, "cached-a", "cached\n") },
    });
    app.pages.changes.changes_projection.cacheOrClearDisplayed(
        allocator,
        .{},
        roots.a,
        .unstaged,
        source_revision,
        status_revision,
    );
    app.pages.changes.changes_projection.installReady(.{
        .request = try app_changes_projection.testing.cloneRequest(
            allocator,
            page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
            2,
            roots.a,
            "displayed-a",
            .generated_added_file,
            .unstaged,
            source_revision,
            status_revision,
        ),
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(allocator, "displayed-a", "displayed\n") },
    });
    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        allocator,
        page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
        3,
        roots.a,
        "pending-a",
        .generated_added_file,
        .unstaged,
        source_revision,
        status_revision,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.changes_projection.cacheLen());

    try publishPathDiscovery(
        &app,
        &ctx.ctx,
        allocator,
        roots.b,
        try testSingleRepoDiscovery(allocator, roots.b),
    );
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.changes.load.state == .idle);
    try std.testing.expect(changesNavigation(&app).activeLoadedDiff() == null);
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(!app.pages.changes.changes_projection.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.changes_projection.cacheLen());
    try std.testing.expect(!app.pages.changes.changes_projection.cacheHas(
        .{},
        roots.a,
        "cached-a",
        .generated_added_file,
        .unstaged,
        source_revision,
        status_revision,
    ));

    try requestPageSwitchForTest(&app, &ctx.ctx, .changes);

    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.changes_projection.cacheLen());
    var pending = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending) |*task| task.deinit();
    pending[0].deinit();
    pending[1].deinit();
    var diff_message = try pending[2].fail(error.ConcurrencyUnavailable);
    defer diff_message.deinitUndelivered(allocator);
    const diff_task = diff_message.load_finished.changes.source;
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    try std.testing.expectEqual(app.repo_session.repo_epoch, diff_task.identity.repo_epoch);
}
test "inactive Changes failure stays page scoped and skips redraw" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 5,
        },
        .pages = .{ .changes = .{ .status_load = .{
            .generation = 1,
            .pending = .{ .generation = 1 },
        } } },
    };
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = page.RequestIdentity.changes(5, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "offline" },
    } } }), &ctx.ctx);

    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("status load failed: offline", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}
test "manual reload queues revalidation without superseding an action cursor pair" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .{ .patch_file = "change.patch" } },
    };
    _ = activateChanges(&app);
    defer changesNavigation(&app).clearActionCursor(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try installTestActionCursor(&app, std.testing.allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);

    try app.update(.reload, &ctx.ctx);

    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(
        app.pages.changes.activation.currentIdentity().?.activation_id,
        app.pages.changes.activation.revalidation_requested.?,
    );
}
test "Changes canonical publication page transition drains source-first results and starts fresh revalidation" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    const cases = [_]struct {
        source: CanonicalPageTransitionSource,
        exit_input: CanonicalPageTransitionInput,
        entry_input: CanonicalPageTransitionInput,
    }{
        .{ .source = .changed, .exit_input = .keyboard, .entry_input = .page_bar },
        .{ .source = .unchanged, .exit_input = .page_bar, .entry_input = .keyboard },
        .{ .source = .empty, .exit_input = .keyboard, .entry_input = .keyboard },
    };

    for (cases) |case| {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();

        const prior = changesNavigationView(&app).activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        const source_revision = app.pages.changes.source_session_revision;
        const status_revision = app.pages.changes.status_snapshot_revision;
        const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        try finishCanonicalPageTransitionSource(
            &app,
            &ctx.ctx,
            allocator,
            reads,
            case.source,
        );
        try std.testing.expect(app.pages.changes.deferred_source_apply != null);
        try std.testing.expect(!app.pages.changes.deferredSourceBlocksPageTransition());
        for (0..6) |_| try applyCanonicalPageTransitionFilterToggle(&app, &ctx.ctx);

        try requestCanonicalPageTransition(
            &app,
            &ctx,
            .repository,
            case.exit_input,
        );
        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expect(app.pages.changes.activation.state == .inactive);
        try std.testing.expect(app.pages.changes.canonical_publication == null);
        try std.testing.expect(app.pages.changes.deferred_source_apply == null);
        try std.testing.expect(app.pages.changes.canonical_status_drain != null);
        try expectRetainedCanonicalPageTransitionBody(
            &app,
            prior_hunks,
            source_revision,
            status_revision,
        );
        for (0..2) |_| try applyCanonicalPageTransitionFilterToggle(&app, &ctx.ctx);

        try requestCanonicalPageTransition(
            &app,
            &ctx,
            .changes,
            case.entry_input,
        );
        const new_activation = app.pages.changes.activation.currentIdentity() orelse
            return error.ExpectedChangesActivation;
        try std.testing.expect(new_activation.activation_id != reads.source_identity.activation_id);
        try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());

        try finishCanonicalPublicationStatus(
            &app,
            &ctx.ctx,
            allocator,
            roots.a,
            reads,
            "MM a\x00",
        );
        try std.testing.expect(app.pages.changes.canonical_status_drain == null);
        try finishCanonicalPageTransitionBranch(
            &app,
            &ctx.ctx,
            allocator,
            roots.a,
            reads,
        );
        try expectRetainedCanonicalPageTransitionBody(
            &app,
            prior_hunks,
            source_revision,
            status_revision,
        );
        try expectFreshCanonicalPageTransitionReads(
            &app,
            &ctx,
            allocator,
            reads.source_identity,
        );
    }
}
test "Changes canonical publication page transition drains status-first source without stale publication" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const source_revision = app.pages.changes.source_session_revision;
    const status_revision = app.pages.changes.status_snapshot_revision;
    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        reads,
        "MM a\x00",
    );
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);

    try requestCanonicalPageTransition(&app, &ctx, .repository, .page_bar);
    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(app.pages.changes.canonical_status_drain == null);
    try requestCanonicalPageTransition(&app, &ctx, .changes, .keyboard);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());

    try finishCanonicalPageTransitionSource(
        &app,
        &ctx.ctx,
        allocator,
        reads,
        .changed,
    );
    try finishCanonicalPageTransitionBranch(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        reads,
    );
    try expectRetainedCanonicalPageTransitionBody(
        &app,
        prior_hunks,
        source_revision,
        status_revision,
    );
    try expectFreshCanonicalPageTransitionReads(
        &app,
        &ctx,
        allocator,
        reads.source_identity,
    );
}
test "Changes canonical publication page transition retires an old projection request" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const source_revision = app.pages.changes.source_session_revision;
    const status_revision = app.pages.changes.status_snapshot_revision;
    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        reads,
        "MM a\x00",
    );
    try finishCanonicalPageTransitionSource(
        &app,
        &ctx.ctx,
        allocator,
        reads,
        .changed,
    );
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    var old_request = try takeCanonicalPublicationProjectionRequest(&ctx);
    var old_request_owned = true;
    defer if (old_request_owned) old_request.deinit(allocator);
    try std.testing.expect(app.pages.changes.changes_projection.pending != null);

    try requestCanonicalPageTransition(&app, &ctx, .repository, .keyboard);
    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try requestCanonicalPageTransition(&app, &ctx, .changes, .page_bar);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = old_request,
        .result = .{ .failed_static = "stale projection" },
    } } }), &ctx.ctx);
    old_request_owned = false;
    try finishCanonicalPageTransitionBranch(
        &app,
        &ctx.ctx,
        allocator,
        roots.a,
        reads,
    );
    try expectRetainedCanonicalPageTransitionBody(
        &app,
        prior_hunks,
        source_revision,
        status_revision,
    );
    try expectFreshCanonicalPageTransitionReads(
        &app,
        &ctx,
        allocator,
        reads.source_identity,
    );
}
test "Changes canonical publication page transition retires generic page exits" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]page.Id{ .history, .compare }, 0..) |target, index| {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        _ = try startCanonicalPublicationWatch(&app, &ctx, allocator);

        try requestCanonicalPageTransition(
            &app,
            &ctx,
            target,
            if (index == 0) .keyboard else .page_bar,
        );

        try std.testing.expectEqual(target, app.active_page);
        try std.testing.expect(app.pages.changes.activation.state == .inactive);
        try std.testing.expect(app.pages.changes.canonical_publication == null);
        try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    }
}
test "Changes canonical publication retains the prior body for every direct action arrival order" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]CanonicalPublicationAction{ .stage_file, .unstage_file, .discard_file, .commit }) |action| {
        for ([_]bool{ false, true }) |status_first| {
            for ([_]bool{ false, true }) |source_empty| {
                var app = try canonicalPublicationTestApp(allocator, roots.a);
                defer app.pages.changes.deinit(allocator);
                defer app.repo_session.repo_state.deinit(allocator);
                var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
                ctx.init(allocator, std.testing.io);
                defer ctx.deinit();

                const prior = changesNavigationView(&app).activeCombinedProjection() orelse
                    return error.ExpectedCombinedProjection;
                const prior_hunks = prior.displayFile().hunks.ptr;
                const prior_content_token = prior.presentation.content_token;
                const source_revision_before = app.pages.changes.source_session_revision;
                const status_revision_before = app.pages.changes.status_snapshot_revision;
                try finishCanonicalPublicationAction(&app, &ctx.ctx, allocator, action, roots.a);
                const reads = try takeCanonicalPublicationReads(&ctx, allocator);
                app.screen_transition.arm(app.pages.changes.activation.currentIdentity().?);

                if (status_first) {
                    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
                    try expectRetainedCanonicalPublication(&app, prior_hunks);
                }
                if (source_empty) {
                    try finishCanonicalPublicationEmpty(&app, &ctx.ctx, reads);
                } else {
                    try finishCanonicalPublicationSource(
                        &app,
                        &ctx.ctx,
                        allocator,
                        reads,
                        app_test_support.diff_unstaged_projection,
                    );
                }
                try expectRetainedCanonicalPublication(&app, prior_hunks);
                if (!status_first) {
                    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
                    try expectRetainedCanonicalPublication(&app, prior_hunks);
                }

                try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
                try std.testing.expect(app.screen_transition == .waiting);
                var request = try takeCanonicalPublicationProjectionRequest(&ctx);
                if (source_empty) {
                    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, request.kind);
                    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
                        .request = request,
                        .result = .{ .ready = .{
                            .cached_diff = try app_load.buildLoadedBundle(
                                allocator,
                                app_test_support.diff_cached_projection,
                            ),
                        } },
                    } } }), &ctx.ctx);
                } else {
                    try std.testing.expectEqual(app_changes_projection.Kind.combined_hunks, request.kind);
                    const final_bundle = try canonicalPublicationFinalBundle(allocator, request);
                    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
                        .request = request,
                        .result = .{ .ready = .{ .combined_hunks = final_bundle } },
                    } } }), &ctx.ctx);
                }
                try std.testing.expect(app.screen_transition == .running);
                request = undefined;
                try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

                if (source_empty) {
                    try expectFreshCanonicalCachedPublication(
                        &app,
                        allocator,
                        roots.a,
                        prior_content_token,
                        source_revision_before + 1,
                        status_revision_before,
                    );
                } else {
                    try expectFreshCanonicalPublication(
                        &app,
                        allocator,
                        roots.a,
                        prior_hunks,
                        prior_content_token,
                        source_revision_before + 1,
                        status_revision_before,
                        true,
                    );
                }
                try std.testing.expect(app.pages.changes.pending_reload == null);
                try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
            }
        }
    }
}
test "Changes canonical publication retains the prior body for a stage hunk successor watch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const hunk_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", hunk_pending.generation);
    try app.update(App.Msg.actionFinished(.{ .stage_hunk = .{
        .pending = hunk_pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    } }), &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var hunk_entries = ctx.takeTask(0).?;
    defer hunk_entries.deinit();
    var hunk_status_message = try hunk_entries.fail(error.ConcurrencyUnavailable);
    defer hunk_status_message.deinitUndelivered(allocator);
    const hunk_status_task = hunk_status_message.load_finished.changes.status;
    const hunk_identity = hunk_status_task.identity;
    const hunk_read_epoch = hunk_status_task.read_epoch;
    const hunk_generation = hunk_status_task.generation;
    var hunk_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = hunk_identity,
        .read_epoch = hunk_read_epoch,
        .generation = hunk_generation,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = hunk_status },
    } } }), &ctx.ctx);
    hunk_status = undefined;
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    var hunk_projection_request = try takeCanonicalPublicationProjectionRequest(&ctx);
    try std.testing.expectEqual(
        app_changes_projection.Kind.combined_hunks,
        hunk_projection_request.kind,
    );
    const hunk_projection = try canonicalPublicationFinalBundle(
        allocator,
        hunk_projection_request,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = hunk_projection_request,
        .result = .{ .ready = .{ .combined_hunks = hunk_projection } },
    } } }), &ctx.ctx);
    hunk_projection_request = undefined;

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const prior_content_token = prior.presentation.content_token;
    const source_revision_before = app.pages.changes.source_session_revision;
    const status_revision_before = app.pages.changes.status_snapshot_revision;
    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
    try finishCanonicalPublicationSource(&app, &ctx.ctx, allocator, reads, reordered_action_refresh_diff);
    try expectCanonicalPublicationCycleTransfer(&app, cycle_id);
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00 M b\x00");
    try expectRetainedCanonicalPublication(&app, prior_hunks);

    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx);
    const final_bundle = try canonicalPublicationFinalBundle(allocator, request);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = request,
        .result = .{ .ready = .{ .combined_hunks = final_bundle } },
    } } }), &ctx.ctx);
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
    try expectFreshCanonicalPublication(
        &app,
        allocator,
        roots.a,
        prior_hunks,
        prior_content_token,
        source_revision_before + 1,
        status_revision_before + 1,
        true,
    );
}
test "background status completion during repository action is discarded and releases cycle" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.changes.git_status.deinit();
    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M old.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);

    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .status));
    const generation = app.pages.changes.status_load.prepare(true);
    app.pages.changes.status_load.begin(cycle_id, .{});
    _ = beginAcceptedTestAction(&app, .stage_file);
    const changed = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M new.zig\x00");
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = changed },
    } } }), &ctx.ctx);

    try std.testing.expectEqualStrings("old.zig", app.pages.changes.git_status.document.entries[0].path);
    try std.testing.expect(!app.pages.changes.status_load.isPending());
    try std.testing.expectEqual(app_auto_reload.AuxiliaryFreshness.stale_refresh, app.pages.changes.status_load.freshness);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}
test "background source completion during repository action is discarded and releases cycle" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const accepted = content_fingerprint.Fingerprint.init("old");
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer changesReload(&app).clearPendingReload(std.testing.allocator);
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    app.pages.changes.auto_reload.acceptSource(accepted);
    syncTestActivation(&app);
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .source));
    const pending = beginAcceptedTestAction(&app, .stage_file);
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    } } }), &ctx.ctx);

    try std.testing.expectEqualStrings("old", changesNavigationView(&app).activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(accepted));
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);

    try app.update(App.Msg.actionFinished(.{ .stage_file = .{
        .pending = pending,
        .repo_root = &.{},
        .path = try std.testing.allocator.dupe(u8, "a"),
        .result = .ok,
    } }), &ctx.ctx);
    ownTestSourceRead(&app, 3, .action_result);
    const authoritative = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .read_epoch = app.pages.changes.repository_read_authority.epoch,
        .generation = 3,
        .result = .{ .loaded = authoritative },
    } } }), &ctx.ctx);
    try std.testing.expectEqualStrings(app_test_support.diff_one, changesNavigationView(&app).activeLoadedDiffConst().?.text);
}
test "deferred background source is discarded when a repository action starts" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer changesReload(&app).clearDeferredSourceApply(std.testing.allocator);
    defer changesReload(&app).clearPendingReload(std.testing.allocator);
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    } } }), &ctx.ctx);
    try std.testing.expect(app.pages.changes.deferred_source_apply != null);

    _ = beginAcceptedTestAction(&app, .stage_file);
    changesNavigation(&app).clearDiffSelection();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);

    try std.testing.expectEqualStrings("old", changesNavigationView(&app).activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}
test "empty watch result defers during selection and focus loss applies it" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer changesReload(&app).clearDeferredSourceApply(std.testing.allocator);
    defer changesReload(&app).clearPendingReload(std.testing.allocator);
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .source));
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .empty,
    } } }), &ctx.ctx);
    try std.testing.expect(app.pages.changes.deferred_source_apply != null);
    try std.testing.expectEqualStrings("old", changesNavigationView(&app).activeLoadedDiffConst().?.text);

    try app.update(.focus_lost, &ctx.ctx);
    try std.testing.expect(!app.pages.changes.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}

const CanonicalPublicationAction = enum {
    stage_file,
    unstage_file,
    discard_file,
    commit,

    fn actionKind(self: CanonicalPublicationAction) app_actions.ActionKind {
        return switch (self) {
            .stage_file => .stage_file,
            .unstage_file => .unstage_file,
            .discard_file => .discard_file,
            .commit => .commit,
        };
    }
};

const canonical_publication_combined_diff =
    \\diff --git a/a b/a
    \\index 1..3 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -10,3 +10,3 @@
    \\ context
    \\-old staged
    \\+new staged
    \\ context
    \\@@ -20,3 +20,3 @@
    \\ context
    \\-old unstaged
    \\+new unstaged
    \\ context
    \\
;

pub const CanonicalPublicationReads = struct {
    source_identity: page.RequestIdentity,
    source_read_epoch: changes_page.repository_read_authority.ChangesRepositoryReadEpoch,
    source_generation: u64,
    source_cycle_id: ?u64,
    status_identity: page.RequestIdentity,
    status_read_epoch: changes_page.repository_read_authority.ChangesRepositoryReadEpoch,
    status_generation: u64,
    status_cycle_id: ?u64,
    branch_identity: page.RequestIdentity,
    branch_read_epoch: changes_page.repository_read_authority.ChangesRepositoryReadEpoch,
    branch_generation: u64,
    branch_cycle_id: ?u64,
};

pub fn canonicalPublicationTestApp(
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
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .auto_reload = .init(.enabled, .{}),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = .{ .logical = 1 },
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.changes.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try app.pages.changes.git_status.replace(repo_root, &status);
    app.pages.changes.status_load.markSuccess();
    acceptTestSource(&app);
    const identity = app.pages.changes.activation.currentIdentity() orelse return error.ExpectedChangesActivation;
    var initial_bundle = try testCombinedHunkBundle(allocator);
    initial_bundle.presentation.content_token =
        diff_presentation_identity.ContentToken.init(app.pages.changes.source_session_revision);
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = try app_changes_projection.testing.cloneRequest(
            allocator,
            identity,
            1,
            repo_root,
            "a",
            .combined_hunks,
            .unstaged,
            app.pages.changes.source_session_revision,
            app.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .combined_hunks = initial_bundle },
    } };
    return app;
}

fn canonicalPublicationPrimaryTestApp(
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
        .pages = .{ .changes = .{
            .auto_reload = .init(.enabled, .{}),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = .{ .logical = 1 },
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.changes.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var source = try app_load.buildLoadedBundle(allocator, canonical_publication_combined_diff);
    errdefer source.deinit();
    app.pages.changes.load.replaceLoaded(allocator, .{
        .arena = source.takeArena(),
        .loaded = source.loaded,
        .reviewed_files_owned = false,
    });
    var status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try app.pages.changes.git_status.replace(repo_root, &status);
    app.pages.changes.status_load.markSuccess();
    acceptTestSource(&app);

    const identity = app.pages.changes.activation.currentIdentity() orelse return error.ExpectedChangesActivation;
    var candidate = try canonicalPublicationReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    defer candidate.deinit();
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = try app_changes_projection.testing.cloneRequest(
            allocator,
            identity,
            1,
            repo_root,
            "a",
            .combined_hunks,
            .unstaged,
            app.pages.changes.source_session_revision,
            app.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .primary_combined_authority = candidate.discardCandidateAndTakeAuthority() },
    } };
    return app;
}

fn ordinaryPrimaryPublicationTestApp(
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
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .auto_reload = .init(.enabled, .{}),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
                .diff_scroll = .{ .logical = 1 },
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.changes.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(repo_root, &status);
    app.pages.changes.status_load.markSuccess();
    acceptTestSource(&app);
    try std.testing.expect(app.pages.changes.changes_projection.displayed == .idle);
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() == .primary);
    return app;
}

fn canonicalPublicationReuseCandidate(
    allocator: std.mem.Allocator,
    status_snapshot_revision: u64,
) !app_changes_projection.CombinedReuseCandidate {
    var cached = try app_projection_component.ParsedComponent.parse(
        allocator,
        app_test_support.diff_cached_projection,
    );
    errdefer cached.deinit();
    var unstaged = try app_projection_component.ParsedComponent.parse(
        allocator,
        app_test_support.diff_unstaged_projection,
    );
    errdefer unstaged.deinit();
    var candidate_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer candidate_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        candidate_arena.allocator(),
        authority_arena.allocator(),
        cached.document.files[0],
        unstaged.document.files[0],
    );
    const candidate: app_changes_projection.CombinedReuseCandidate = .{
        .candidate_arena = candidate_arena,
        .projection = projection.presentation,
        .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
        .fresh_authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached,
            .unstaged_component = unstaged,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
    cached.arena = null;
    unstaged.arena = null;
    return candidate;
}

pub fn canonicalPublicationStagedOnlyReuseCandidate(
    allocator: std.mem.Allocator,
    status_snapshot_revision: u64,
) !app_changes_projection.StagedOnlyReuseCandidate {
    var cached = try app_projection_component.ParsedComponent.parse(
        allocator,
        canonical_publication_combined_diff,
    );
    errdefer cached.deinit();
    if (cached.document.files.len != 1) return error.ExpectedSingleCachedFile;
    const owner = cached.arena.?.allocator();
    const hunk_count = cached.document.files[0].hunks.len;
    const stage_states = try owner.alloc(diff_hunk_projection.HunkStageState, hunk_count);
    @memset(stage_states, .staged);
    const action_origins = try owner.alloc(diff_hunk_projection.HunkActionOrigin, hunk_count);
    for (action_origins, 0..) |*origin, hunk_index| {
        origin.* = .{ .cached = hunk_index };
    }
    const candidate: app_changes_projection.StagedOnlyReuseCandidate = .{
        .fingerprint = diff_presentation_identity.fingerprint(cached.document.files[0]),
        .fresh_authority = .{
            .projection = .{
                .hunk_stage_states = stage_states,
                .hunk_action_origins = action_origins,
            },
            .cached_component = cached,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
    cached.arena = null;
    return candidate;
}

fn installCanonicalPublicationLineageOwners(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !content_selection.ContentToken {
    const displayed = changesNavigationView(&app).displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    const token = changesNavigationView(&app).currentContentToken() orelse
        return error.ExpectedContentToken;
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 1, .line_index = 0 },
        .focus = .{ .hunk_index = 1, .line_index = 0 },
        .moved = true,
    };
    app.pages.changes.completed_selection = try content_selection.buildParsed(
        allocator,
        token,
        displayed,
        selection,
    );
    try app.pages.changes.staged_hunks.addExact(allocator, repo_root, "a", .{
        .content = token,
        .display_hunk_index = 1,
    });
    return token;
}

fn finishCanonicalPublicationAction(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    action: CanonicalPublicationAction,
    repo_root: []const u8,
) !void {
    const pending = beginAcceptedTestAction(app, action.actionKind());
    if (action != .commit) {
        try installTestActionCursor(app, allocator, .file, "a", pending.generation);
    }
    switch (action) {
        .stage_file => try app.update(App.Msg.actionFinished(.{ .stage_file = .{
            .pending = pending,
            .repo_root = try allocator.dupe(u8, repo_root),
            .path = try allocator.dupe(u8, "a"),
            .result = .ok,
        } }), ctx),
        .unstage_file => try app.update(App.Msg.actionFinished(.{ .unstage_file = .{
            .pending = pending,
            .repo_root = try allocator.dupe(u8, repo_root),
            .path = try allocator.dupe(u8, "a"),
            .result = .ok,
        } }), ctx),
        .discard_file => try app.update(App.Msg.actionFinished(.{ .discard_file = .{
            .pending = pending,
            .repo_root = try allocator.dupe(u8, repo_root),
            .path = try allocator.dupe(u8, "a"),
            .result = .ok,
        } }), ctx),
        .commit => try app.update(App.Msg.actionFinished(.{ .commit = .{
            .pending = pending,
            .repo_root = try allocator.dupe(u8, repo_root),
            .result = .ok,
        } }), ctx),
    }
}

pub fn takeCanonicalPublicationReads(
    ctx: *chasen.testing.TestCtx(App.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    var entries = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&entries) |*task| task.deinit();
    var status_task_message = try entries[0].fail(error.ConcurrencyUnavailable);
    defer status_task_message.deinitUndelivered(allocator);
    const status_task = status_task_message.load_finished.changes.status;
    var branch_task_message = try entries[1].fail(error.ConcurrencyUnavailable);
    defer branch_task_message.deinitUndelivered(allocator);
    const branch_task = branch_task_message.load_finished.changes.branch_status;
    var source_task_message = try entries[2].fail(error.ConcurrencyUnavailable);
    defer source_task_message.deinitUndelivered(allocator);
    const source_task = source_task_message.load_finished.changes.source;
    const reads: CanonicalPublicationReads = .{
        .source_identity = source_task.identity,
        .source_read_epoch = source_task.read_epoch,
        .source_generation = source_task.generation,
        .source_cycle_id = source_task.background_cycle_id,
        .status_identity = status_task.identity,
        .status_read_epoch = status_task.read_epoch,
        .status_generation = status_task.generation,
        .status_cycle_id = status_task.background_cycle_id,
        .branch_identity = branch_task.identity,
        .branch_read_epoch = branch_task.read_epoch,
        .branch_generation = branch_task.generation,
        .branch_cycle_id = branch_task.background_cycle_id,
    };
    return reads;
}

pub fn startCanonicalPublicationWatch(
    app: *App,
    ctx: *chasen.testing.TestCtx(App.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    try app.update(.auto_reload_tick, &ctx.ctx);
    const reads = try takeCanonicalPublicationReads(ctx, allocator);
    const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
    try std.testing.expectEqual(@as(?u64, cycle_id), reads.status_cycle_id);
    try std.testing.expectEqual(@as(?u64, cycle_id), reads.branch_cycle_id);
    const cycle = app.pages.changes.auto_reload.background_cycle orelse
        return error.ExpectedBackgroundCycle;
    try std.testing.expectEqual(cycle_id, cycle.id);
    try std.testing.expect(cycle.pending.source);
    try std.testing.expect(cycle.pending.status);
    try std.testing.expect(cycle.pending.branch);
    try std.testing.expect(!cycle.pending.deferred_source_apply);
    return reads;
}

fn expectCanonicalPublicationCycleTransfer(
    app: *const App,
    cycle_id: u64,
) !void {
    const deferred = app.pages.changes.deferred_source_apply orelse
        return error.ExpectedDeferredSource;
    try std.testing.expectEqual(cycle_id, deferred.cycle_id);
    const cycle = app.pages.changes.auto_reload.background_cycle orelse
        return error.ExpectedBackgroundCycle;
    try std.testing.expectEqual(cycle_id, cycle.id);
    try std.testing.expect(!cycle.pending.source);
    try std.testing.expect(cycle.pending.deferred_source_apply);
}

pub fn finishCanonicalPublicationStatus(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
    status_text: []const u8,
) !void {
    var status = try git_status.StatusBundle.parseOwned(allocator, status_text);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .loaded = status },
    } } }), ctx);
    status = undefined;
}

fn finishCanonicalPublicationStatusFailure(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
) !void {
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .failed_static = "status failed" },
    } } }), ctx);
}

fn finishCanonicalPublicationSource(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    reads: CanonicalPublicationReads,
    diff: []const u8,
) !void {
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, diff) },
    } } }), ctx);
}

fn finishCanonicalPublicationEmpty(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    reads: CanonicalPublicationReads,
) !void {
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .empty,
    } } }), ctx);
}

pub fn finishCanonicalPublicationBranch(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
) !void {
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .failed_static = "test branch status terminal" },
    } } }), ctx);
}

fn takeCanonicalPublicationProjectionRequest(
    ctx: *chasen.testing.TestCtx(App.Msg),
) !app_changes_projection.Request {
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    const message = try entries.fail(error.ConcurrencyUnavailable);
    // Move the owned request out; the static failure has no separate allocation.
    return message.load_finished.changes.projection.request;
}

fn canonicalPublicationFinalBundle(
    allocator: std.mem.Allocator,
    request: app_changes_projection.Request,
) !app_changes_projection.CombinedHunkBundle {
    var bundle = try testCombinedHunkBundle(allocator);
    bundle.presentation.content_token =
        diff_presentation_identity.ContentToken.init(request.source_session_revision);
    bundle.authority.status_snapshot_revision = request.status_snapshot_revision;
    return bundle;
}

fn expectRetainedCanonicalPublication(
    app: *const App,
    expected_hunks: [*]const diff_parser.Hunk,
) !void {
    const retained = changesNavigationView(app).activeCombinedProjection() orelse
        return error.ExpectedRetainedCanonicalPublication;
    try std.testing.expectEqual(expected_hunks, retained.displayFile().hunks.ptr);
}

fn expectRetainedOrdinaryPrimaryPublication(
    app: *const App,
    expected_loaded: *const loaded_diff.LoadedDiff,
    expected_token: content_selection.ContentToken,
) !void {
    const primary = switch (changesNavigationView(app).displayedChangesBody()) {
        .primary => |value| value,
        else => return error.ExpectedRetainedOrdinaryPrimary,
    };
    try std.testing.expect(primary.loaded == expected_loaded);
    const token = changesNavigationView(app).currentContentToken() orelse
        return error.ExpectedContentToken;
    try std.testing.expect(token.eql(expected_token));
}

fn expectFreshCanonicalActionCapabilities(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    switch (changesOperations(app).stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (changesOperations(app).unstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.changes.viewer.diff_scroll = .{ .logical = 0 };
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (changesOperations(app).selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkUnstageCapability,
    }

    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (changesOperations(app).selectedHunkStageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 1), target.hunk_index);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkStageCapability,
    }
}

fn expectFreshCanonicalPublication(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    prior_hunks: [*]const diff_parser.Hunk,
    prior_content_token: diff_presentation_identity.ContentToken,
    expected_source_revision: u64,
    expected_status_revision: u64,
    verify_action_capabilities: bool,
) !void {
    try std.testing.expectEqual(expected_source_revision, app.pages.changes.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.changes.status_snapshot_revision);
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.changes.status_load.isFresh());

    const request = app.pages.changes.changes_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(request.matchesBorrowed(
        app.pages.changes.repository_read_authority.epoch,
        repo_root,
        "a",
        .combined_hunks,
        .unstaged,
        expected_source_revision,
        expected_status_revision,
    ));
    try std.testing.expect(request.matchesRootIdentity(app.repo_session.view().activeIdentity()));
    const expected_presentation = request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .combined_projection);
    try std.testing.expect(expected_presentation.content_token.eql(prior_content_token));

    const published = changesNavigationView(app).activeCombinedProjection() orelse
        return error.ExpectedFreshCombinedPublication;
    try std.testing.expect(published.displayFile().hunks.ptr != prior_hunks);
    try std.testing.expect(published.presentation.content_token.eql(
        diff_presentation_identity.ContentToken.init(expected_source_revision),
    ));
    try std.testing.expectEqual(
        expected_status_revision,
        published.authority.status_snapshot_revision,
    );

    const authority = changesNavigationView(app).activeHunkAuthority() orelse
        return error.ExpectedFreshHunkAuthority;
    try std.testing.expect(authority.authority == .combined);
    try std.testing.expectEqual(expected_status_revision, authority.authority.statusSnapshotRevision());
    try std.testing.expectEqual(@as(usize, 2), authority.hunkStageStates().len);
    try std.testing.expectEqual(@as(usize, 2), authority.hunkActionOrigins().len);
    try std.testing.expectEqual(
        diff_hunk_projection.HunkStageState.staged,
        authority.hunkStageStates()[0],
    );
    try std.testing.expectEqual(
        diff_hunk_projection.HunkStageState.unstaged,
        authority.hunkStageStates()[1],
    );
    try std.testing.expect(authority.hunkActionOrigins()[0] == .cached);
    try std.testing.expect(authority.hunkActionOrigins()[1] == .unstaged);
    const cached_source = authority.actionSourceFile(authority.hunkActionOrigins()[0]) orelse
        return error.ExpectedFreshCachedActionSource;
    const unstaged_source = authority.actionSourceFile(authority.hunkActionOrigins()[1]) orelse
        return error.ExpectedFreshUnstagedActionSource;
    try std.testing.expectEqualStrings("a", diff_file.canonicalPathKey(cached_source).?);
    try std.testing.expectEqualStrings("a", diff_file.canonicalPathKey(unstaged_source).?);
    if (verify_action_capabilities) {
        try expectFreshCanonicalActionCapabilities(app, allocator, repo_root);
    }
}

fn expectFreshCanonicalCachedPublication(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    prior_content_token: diff_presentation_identity.ContentToken,
    expected_source_revision: u64,
    expected_status_revision: u64,
) !void {
    try std.testing.expectEqual(expected_source_revision, app.pages.changes.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.changes.status_snapshot_revision);
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.changes.status_load.isFresh());

    const request = app.pages.changes.changes_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(request.matchesBorrowed(
        app.pages.changes.repository_read_authority.epoch,
        repo_root,
        "a",
        .cached_diff,
        .unstaged,
        expected_source_revision,
        expected_status_revision,
    ));
    try std.testing.expect(request.matchesRootIdentity(app.repo_session.view().activeIdentity()));
    const expected_presentation = request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .combined_projection);
    try std.testing.expect(expected_presentation.content_token.eql(prior_content_token));
    try std.testing.expect(changesNavigationView(app).displayedChangesBody() == .cached);
    try std.testing.expect(changesNavigationView(app).activeCachedDiffProjection() != null);

    switch (changesOperations(app).stageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (changesOperations(app).unstageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.changes.viewer.diff_scroll = .{ .logical = 0 };
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (changesOperations(app).selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(
            ToggleStageOperation.unstage,
            operation,
        ),
        else => return error.ExpectedFreshHunkUnstageOperation,
    }
    switch (changesOperations(app).selectedHunkStageTarget(allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedHunk,
    }
    switch (changesOperations(app).selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkUnstageCapability,
    }
}

const CanonicalPageTransitionInput = enum {
    keyboard,
    page_bar,
};

const CanonicalPageTransitionSource = enum {
    changed,
    unchanged,
    empty,
};

fn canonicalPageTransitionMessage(
    app: *App,
    target: page.Id,
    input: CanonicalPageTransitionInput,
) !App.Msg {
    return switch (input) {
        .keyboard => app.handleEvent(.{ .key_press = .{
            .codepoint = switch (target) {
                .changes => '1',
                .repository => '2',
                .history => '3',
                .compare => '4',
            },
        } }),
        .page_bar => blk: {
            const bar = app_shell_layout.compute(
                app.terminal_size,
                .{ .page_bar_visible = true },
            ).page_bar orelse return error.ExpectedPageBar;
            const tab = page.tab(target);
            break :blk app.handleEvent(app_test_support.mouseEvent(
                bar.col + tab.col,
                bar.row,
                .left,
            ));
        },
    } orelse error.ExpectedPageSwitch;
}

fn requestCanonicalPageTransition(
    app: *App,
    ctx: *chasen.testing.TestCtx(App.Msg),
    target: page.Id,
    input: CanonicalPageTransitionInput,
) !void {
    const message = try canonicalPageTransitionMessage(app, target, input);
    switch (message) {
        .switch_page => |requested| {
            try std.testing.expectEqual(target, requested);
            try requestPageSwitchForTest(app, &ctx.ctx, requested);
            if (requested == .repository) {
                ctx.discardPendingTasks();
            }
        },
        else => return error.ExpectedPageSwitch,
    }
}

fn applyCanonicalPageTransitionFilterToggle(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
) !void {
    const message = app.handleEvent(.{ .key_press = .{ .codepoint = 'F' } }) orelse
        return error.ExpectedFilterToggle;
    switch (message) {
        .changes, .repository => try app.update(message, ctx),
        else => return error.ExpectedFilterToggle,
    }
}

fn finishCanonicalPageTransitionSource(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    reads: CanonicalPublicationReads,
    result: CanonicalPageTransitionSource,
) !void {
    switch (result) {
        .changed => try finishCanonicalPublicationSource(
            app,
            ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        ),
        .unchanged => try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
            .identity = reads.source_identity,
            .read_epoch = reads.source_read_epoch,
            .generation = reads.source_generation,
            .background_cycle_id = reads.source_cycle_id,
            .result = .{
                .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
            },
        } } }), ctx),
        .empty => try finishCanonicalPublicationEmpty(app, ctx, reads),
    }
}

fn finishCanonicalPageTransitionBranch(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
) !void {
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .empty,
    } } }), ctx);
}

fn expectFreshCanonicalPageTransitionReads(
    app: *App,
    ctx: *chasen.testing.TestCtx(App.Msg),
    allocator: std.mem.Allocator,
    old_identity: page.RequestIdentity,
) !void {
    // Public completion delivery runs the exact App update tail, so the fresh
    // revalidation may already have started in that same turn. If not, give
    // the retained intent one neutral scheduling opportunity.
    if (ctx.pendingTaskCount() == 0) {
        try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    }
    const fresh = try takeCanonicalPublicationReads(ctx, allocator);
    const active = app.pages.changes.activation.currentIdentity() orelse
        return error.ExpectedChangesActivation;
    try std.testing.expect(active.activation_id != old_identity.activation_id);
    try std.testing.expectEqual(active, fresh.source_identity);
    try std.testing.expectEqual(active, fresh.status_identity);
    try std.testing.expectEqual(active, fresh.branch_identity);
}

fn expectRetainedCanonicalPageTransitionBody(
    app: *const App,
    prior_hunks: [*]const diff_parser.Hunk,
    source_revision: u64,
    status_revision: u64,
) !void {
    try expectRetainedCanonicalPublication(app, prior_hunks);
    try std.testing.expectEqual(source_revision, app.pages.changes.source_session_revision);
    try std.testing.expectEqual(status_revision, app.pages.changes.status_snapshot_revision);
}
