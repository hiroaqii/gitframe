//! Owner-local contract tests for Changes-local Git workflows.
//!
//! The harness composes the workflow with concrete Changes/repository ports and
//! the read bridge used by local action outcomes. It does not import the root
//! App dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const app_auto_reload = @import("../auto_reload.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const app_projection_component = @import("../projection_component.zig");
const app_changes_projection = @import("../changes_projection.zig");
const page = @import("../page.zig");
const repo_session = @import("../repo_session.zig");
const changes_page = @import("../pages/changes.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const changes_read = @import("../pages/changes/read_coordinator.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const action_lifecycle = @import("action_lifecycle.zig");
const workflow_local = @import("local.zig");

const config_mod = @import("../../config.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_hunk_projection = @import("../../diff/hunk_projection.zig");
const diff_presentation_identity = @import("../../diff/presentation_identity.zig");
const diff_source = @import("../../diff/source.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const git_status = @import("../../git/status.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const changes_authority = @import("../diff_surface/authority.zig");

const StageFileFinished = app_actions.StageFileFinished;
const StageHunkFinished = app_actions.StageHunkFinished;
const UnstageFileFinished = app_actions.UnstageFileFinished;
const UnstageHunkFinished = app_actions.UnstageHunkFinished;
const CommitMessageAssistFinished = app_actions.CommitMessageAssistFinished;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const git_ops = @import("../git_ops.zig");
const SessionHunkMarkMutation = git_ops.SessionHunkMarkMutation;
const TargetKind = git_ops.TargetKind;
const ToggleStageOperation = git_ops.ToggleStageOperation;

fn runLocalTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn localTestGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return error.GitCommandFailed;
}

fn expectLocalRootCapabilityClosed(observer: repo_root_capability.RootCapability) !void {
    if (observer.duplicate()) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.ExpectedClosedRootCapability;
    } else |err| try std.testing.expectEqual(error.InvalidRootCapability, err);
}

const LocalPages = struct {
    changes: changes_page.ChangesPageState = .{},
};

const LocalConfig = struct {
    source: diff_source.SourceMode = .unstaged,
};

const RedrawPlan = struct {
    skip_requested: bool = false,
    frame_required: bool = false,
};

const LocalHarness = struct {
    pub const Msg = app_message.Msg;

    active_page: page.Id = .changes,
    repo_session: repo_session.State = .{},
    pages: LocalPages = .{},
    config: LocalConfig = .{},
    user_config: config_mod.Config = .{},
    allocator: ?std.mem.Allocator = std.testing.allocator,
    terminal_size: chasen.Size = .{ .width = 100, .height = 20 },
    redraw_plan: RedrawPlan = .{},
    action_runtime: action_lifecycle.ActionRuntime = .{},
    local_workflow: workflow_local.LocalState = .{},
    overlay: app_state.OverlayState = .{},
    env_map: ?*std.process.Environ.Map = null,

    fn repoSessionView(self: *const LocalHarness) repo_session.View {
        return self.repo_session.view();
    }

    fn bodyLayout(self: *const LocalHarness) @import("../diff_surface.zig").Layout {
        const body = app_shell_layout.compute(self.terminal_size, .{ .page_bar_visible = true }).bodySize();
        return .{ .width = body.width, .height = body.height };
    }

    fn changesNavigation(self: *LocalHarness) changes_navigation.Controller {
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
            .diagnostics = .{ .target = &self.pages.changes.status },
        };
    }

    fn changesNavigationView(self: *const LocalHarness) changes_navigation.View {
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
        };
    }

    fn changesOperations(self: *const LocalHarness) changes_operations.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.changes.activation.state,
        };
    }

    fn changesOperationController(self: *LocalHarness) changes_operations.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .view_state = self.changesOperations(),
        };
    }

    fn changesActionFence(self: *LocalHarness) changes_action_fence.Controller {
        return .{
            .read_authority = &self.pages.changes.repository_read_authority,
            .activation = &self.pages.changes.activation,
            .action_cursor = &self.pages.changes.action_cursor,
            .auto_reload = &self.pages.changes.auto_reload,
            .changes_projection = &self.pages.changes.changes_projection,
            .deferred_projection_apply = &self.pages.changes.deferred_projection_apply,
        };
    }

    fn actionLifecycle(self: *LocalHarness) action_lifecycle.Controller {
        return .{
            .runtime = &self.action_runtime,
            .fence = self.changesActionFence(),
        };
    }

    fn actionLifecycleView(self: *const LocalHarness) action_lifecycle.View {
        return self.action_runtime.view();
    }

    fn currentChangesActionRoot(self: *const LocalHarness) ?[]const u8 {
        if (self.active_page != .changes or
            self.pages.changes.activation.currentIdentity() == null) return null;
        return self.repoSessionView().activeRoot();
    }

    fn localWorkflow(self: *LocalHarness) workflow_local.Controller {
        return .{
            .state = &self.local_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.changesOperationController(),
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .env_map = self.env_map,
            .user_config = &self.user_config,
            .status = &self.pages.changes.status,
            .overlay = &self.overlay,
        };
    }

    fn changesRead(self: *LocalHarness) changes_read.Controller {
        return .{
            .page_state = &self.pages.changes,
            .fence = self.changesActionFence().view(),
            .active_page = self.active_page,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
            .env_map = null,
            .allocator = self.allocator,
            .redraw = .{
                .skip_requested = &self.redraw_plan.skip_requested,
                .frame_required = &self.redraw_plan.frame_required,
            },
            .shell_blockers = .{ .action_pending = self.actionLifecycleView().hasPending() },
        };
    }

    fn changesReload(self: *LocalHarness) changes_reload.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
        };
    }

    fn applyLocalActionIntent(
        self: *LocalHarness,
        ctx: *chasen.Ctx(Msg),
        maybe_intent: ?workflow_local.ActionReloadIntent,
    ) !void {
        const intent = maybe_intent orelse return;
        try self.changesRead().applyActionOutcome(ctx, intent.pending, intent.active_matches, intent.reload);
    }
};

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

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

fn activateTestChanges(app: *LocalHarness) void {
    _ = app.pages.changes.activation.activate(
        app.repo_session.repo_epoch,
        .pending,
        .pending,
        .pending,
    );
}

fn syncTestActivation(app: *LocalHarness) void {
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

fn acceptTestSource(app: *LocalHarness) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn beginAcceptedTestAction(
    app: *LocalHarness,
    kind: app_actions.ActionKind,
) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    const prepared = app.actionLifecycle().prepare(kind);
    return app.actionLifecycle().acceptSpawn(app.allocator.?, prepared).pending;
}

fn installTestActionCursor(
    app: *LocalHarness,
    allocator: std.mem.Allocator,
    kind: changes_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repoSessionView().activeIdentity() orelse test_action_root_identity;
    var prepared = try app.changesNavigation().prepareActionCursor(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        kind,
        path_key,
    );
    app.changesNavigation().installActionCursor(allocator, &prepared, action_generation);
}

fn finishStageFileForTest(
    app: *LocalHarness,
    ctx: *chasen.Ctx(LocalHarness.Msg),
    finished: StageFileFinished,
) !void {
    try app.applyLocalActionIntent(ctx, app.localWorkflow().finishStageFile(ctx.allocator(), finished));
}

fn finishStageHunkForTest(
    app: *LocalHarness,
    ctx: *chasen.Ctx(LocalHarness.Msg),
    finished: StageHunkFinished,
) !void {
    try app.applyLocalActionIntent(ctx, app.localWorkflow().finishStageHunk(ctx.allocator(), finished));
}

fn finishUnstageFileForTest(
    app: *LocalHarness,
    ctx: *chasen.Ctx(LocalHarness.Msg),
    finished: UnstageFileFinished,
) !void {
    try app.applyLocalActionIntent(ctx, app.localWorkflow().finishUnstageFile(ctx.allocator(), finished));
}

fn finishUnstageHunkForTest(
    app: *LocalHarness,
    ctx: *chasen.Ctx(LocalHarness.Msg),
    finished: UnstageHunkFinished,
) !void {
    try app.applyLocalActionIntent(ctx, app.localWorkflow().finishUnstageHunk(ctx.allocator(), finished));
}

fn initStageHunkLaunchLocalHarness(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !LocalHarness {
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
    var app: LocalHarness = .{
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

fn testLocalHarnessWithCommitPanel() LocalHarness {
    return .{
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
        .repo_session = .{ .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } } },
    };
}

fn commitMessageAssistFinished(
    allocator: std.mem.Allocator,
    pending: app_actions.PendingAction,
    launch_revision: u64,
    mode: app_actions.CommitMessageAssistMode,
    result: app_actions.CommitMessageActionResult,
) !CommitMessageAssistFinished {
    const repo_root = try allocator.dupe(u8, "/repo");
    errdefer allocator.free(repo_root);
    const action_id = try allocator.dupe(u8, "commit-message");
    return .{
        .pending = pending,
        .repo_root = repo_root,
        .action_id = action_id,
        .launch_revision = launch_revision,
        .mode = mode,
        .result = result,
    };
}

fn currentTestSessionHunkMarkKey(
    app: *const LocalHarness,
    display_hunk_index: usize,
) !git_ops.SessionHunkMarkKey {
    return .{
        .content = app.changesNavigationView().currentContentToken() orelse
            return error.ExpectedContentToken,
        .display_hunk_index = display_hunk_index,
    };
}

fn addCurrentTestSessionHunkMark(
    app: *LocalHarness,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    path: []const u8,
    display_hunk_index: usize,
) !void {
    try app.pages.changes.staged_hunks.addExact(
        allocator,
        repo_root,
        path,
        try currentTestSessionHunkMarkKey(app, display_hunk_index),
    );
}

fn clearPendingStatusTasks(
    ctx: *chasen.Ctx(LocalHarness.Msg),
    allocator: std.mem.Allocator,
) void {
    for (ctx.takePendingTasksWith()) |entry| {
        const task: *StatusLoadTask = @ptrCast(@alignCast(entry.ctx));
        StatusLoadTask.destroy(task, allocator);
    }
}

fn clearPendingStatusAndDiffTasks(
    ctx: *chasen.Ctx(LocalHarness.Msg),
    allocator: std.mem.Allocator,
) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn testCombinedHunkBundle(
    allocator: std.mem.Allocator,
) !app_changes_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection);
    errdefer cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_unstaged_projection);
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

fn abandonSingleQueuedAction(
    app: *LocalHarness,
    ctx: *chasen.Ctx(LocalHarness.Msg),
) !void {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const message = entries[0].failed(entries[0].ctx, .runtime_abandoned, ctx.allocator());
    switch (message) {
        .action_finished => |finished| switch (finished) {
            .stage_file => |result| try finishStageFileForTest(app, ctx, result),
            .stage_hunk => |result| try finishStageHunkForTest(app, ctx, result),
            .unstage_file => |result| try finishUnstageFileForTest(app, ctx, result),
            .unstage_hunk => |result| try finishUnstageHunkForTest(app, ctx, result),
            .discard_file => |result| try app.applyLocalActionIntent(
                ctx,
                app.localWorkflow().finishDiscardFile(ctx.allocator(), result),
            ),
            else => return error.ExpectedLocalActionTerminal,
        },
        else => return error.ExpectedLocalActionTerminal,
    }

    _ = try app.changesRead().maybeStartQueuedRevalidation(ctx);
    const revalidation = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 3), revalidation.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(revalidation[0].ctx));
    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(revalidation[1].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(revalidation[2].ctx));
    const status_terminal: app_auto_reload.AuxiliaryTerminal = .{
        .generation = status_task.generation,
        .read_epoch = status_task.read_epoch,
        .background_cycle_id = status_task.background_cycle_id,
    };
    const branch_terminal: app_auto_reload.AuxiliaryTerminal = .{
        .generation = branch_task.generation,
        .read_epoch = branch_task.read_epoch,
        .background_cycle_id = branch_task.background_cycle_id,
    };
    const source_generation = source_task.generation;

    for (revalidation) |entry| {
        var completion = entry.failed(entry.ctx, .runtime_abandoned, ctx.allocator());
        completion.deinitUndelivered(ctx.allocator());
    }
    _ = app.changesReload().rejectSourceSpawn(ctx.allocator(), source_generation);
    _ = app.pages.changes.status_load.finishTerminal(status_terminal);
    _ = app.pages.changes.branch_status_load.finishTerminal(branch_terminal);
    app.pages.changes.status_load.markSuccess();
    app.pages.changes.branch_status_load.markSuccess();
    app.pages.changes.canonical_status_drain = null;
    syncTestActivation(app);
}

test "Changes mutation read fence ignores rejected hunk task launch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchLocalHarness(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    const epoch_before_rejection = app.pages.changes.repository_read_authority.epoch;

    var ctx: chasen.Ctx(LocalHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 16,
    };
    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedHunk(&ctx));
    ctx._pending_tasks_with_len = 0;

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(
        app.pages.changes.repository_read_authority.epoch.eql(epoch_before_rejection),
    );
}

test "Changes Git target kinds map to typed action cursor kinds" {
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.repository_root, workflow_local.testing.actionCursorKindForTest(.repository));
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.directory, workflow_local.testing.actionCursorKindForTest(.directory));
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.file, workflow_local.testing.actionCursorKindForTest(.file));
}

test "file and hunk action repository mismatch clear only their matching cursor owner" {
    const allocator = std.testing.allocator;
    var app: LocalHarness = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.changesNavigation().clearActionCursor(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };

    const stage_pending = beginAcceptedTestAction(&app, .stage_file);
    try installTestActionCursor(&app, allocator, .file, "src/stage.zig", stage_pending.generation);
    try finishStageFileForTest(&app, &ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/stage.zig"),
        .result = .ok,
    });
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const unstage_pending = beginAcceptedTestAction(&app, .unstage_file);
    try installTestActionCursor(&app, allocator, .file, "src/unstage.zig", unstage_pending.generation);
    try finishUnstageFileForTest(&app, &ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/unstage.zig"),
        .result = .ok,
    });
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const hunk_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "src/hunk.zig", hunk_pending.generation);
    try finishStageHunkForTest(&app, &ctx, .{
        .pending = hunk_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/hunk.zig"),
        .hunk_index = 0,
        .session_mark_mutation = .none,
        .result = .ok,
    });
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "hunk tasks launch exact typed file owners for stage and unstage" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchLocalHarness(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };

    try app.localWorkflow().stageSelectedHunk(&ctx);
    const pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingHunkAction;
    try std.testing.expectEqual(app_actions.ActionKind.stage_hunk, pending.kind);
    try std.testing.expectEqual(pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.file, app.pages.changes.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("a", app.pages.changes.action_cursor.target().?.path_key);

    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 0);
    try app.localWorkflow().unstageSelectedHunk(&ctx);
    const unstage_pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingHunkAction;
    try std.testing.expectEqual(app_actions.ActionKind.unstage_hunk, unstage_pending.kind);
    try std.testing.expectEqual(unstage_pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.file, app.pages.changes.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("a", app.pages.changes.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "hunk task spawn rejection leaves no action or cursor owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchLocalHarness(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };

    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedHunk(&ctx));
    ctx._pending_tasks_with_len = 0;
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "accepted hunk stage local mark allocation failure bounds its refresh owner" {
    const backing = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var fail_offset: usize = 0;
    while (fail_offset < 3) : (fail_offset += 1) {
        var app = try initStageHunkLaunchLocalHarness(backing, roots.a);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.changes.deinit(backing);

        const pending = beginAcceptedTestAction(&app, .stage_hunk);
        try installTestActionCursor(&app, backing, .file, "a", pending.generation);

        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        const owned_root = try allocator.dupe(u8, roots.a);
        const owned_path = try allocator.dupe(u8, "a");
        failing.fail_index = failing.alloc_index + fail_offset;
        var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };

        try finishStageHunkForTest(&app, &ctx, .{
            .pending = pending,
            .repo_root = owned_root,
            .path = owned_path,
            .hunk_index = 0,
            .session_mark_mutation = .{ .add = try currentTestSessionHunkMarkKey(&app, 0) },
            .result = .ok,
        });

        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(app.pages.changes.status_load.pending == null);
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expectEqual(@as(usize, 0), app.pages.changes.staged_hunks.items.items.len);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    }
}

test "staged summary distinguishes pending missing and ready status snapshots" {
    var app: LocalHarness = .{
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

    try std.testing.expectEqual(app_commit_panel.StagedSummary.unavailable, app.localWorkflow().stagedSummary());

    app.pages.changes.status_load.pending = .{ .generation = 1 };
    syncTestActivation(&app);
    try std.testing.expectEqual(app_commit_panel.StagedSummary.loading_or_stale, app.localWorkflow().stagedSummary());

    app.pages.changes.status_load.pending = null;
    syncTestActivation(&app);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  staged.zig\x00 M unstaged.zig\x00?? new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    try std.testing.expectEqual(app_commit_panel.StagedSummary{ .ready = .{ .count = 1 } }, app.localWorkflow().stagedSummary());
}

test "finishCommitMessageAssist inserts generated editable draft and truncated warning" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = try std.testing.allocator.dupe(u8, "Generated body"),
        .truncated = true,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("Generated subject", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("Generated body", app.local_workflow.commit_panel.body.slice());
    try std.testing.expectEqualStrings("generated commit message from truncated staged diff", app.pages.changes.status.text());
}

test "finishCommitMessageAssist ignores stale result after popup close" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    app.local_workflow.commit_panel.close();
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.local_workflow.commit_panel.is_open);
    try std.testing.expectEqualStrings("", app.local_workflow.commit_panel.subject.slice());
}

test "finishCommitMessageAssist ignores generated draft after user edit" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.local_workflow.commit_panel.insert('x');
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("x", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("generated commit message ignored; draft changed", app.pages.changes.status.text());
}

test "finishCommitMessageAssist failure keeps draft unchanged" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{
        .failed = try std.testing.allocator.dupe(u8, "commit-message: failed"),
    });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(app_commit_panel.CommitError.assist_failed, app.local_workflow.commit_panel.commit_error.?);
    try std.testing.expectEqualStrings("", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("commit-message: failed", app.pages.changes.status.text());
}

test "finishCommitMessageAssist rejects long subject without mutating draft" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    var long_subject: [app_commit_panel.max_subject_chars + 1]u8 = undefined;
    @memset(&long_subject, 'a');
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, &long_subject),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(app_commit_panel.CommitError.subject_too_long, app.local_workflow.commit_panel.commit_error.?);
    try std.testing.expectEqualStrings("", app.local_workflow.commit_panel.subject.slice());
}

test "finishCommitMessageAssist replaces unchanged improved draft" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.paste("Draft subject");
    const snapshot = try workflow_local.testing.buildDraftSnapshot(app.localWorkflow(), std.testing.allocator);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = try std.testing.allocator.dupe(u8, "Improved body"),
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("Improved subject", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("Improved body", app.local_workflow.commit_panel.body.slice());
    try std.testing.expectEqualStrings("improved commit message", app.pages.changes.status.text());
}

test "finishCommitMessageAssist ignores improved draft after user edit" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.paste("Draft subject");
    const snapshot = try workflow_local.testing.buildDraftSnapshot(app.localWorkflow(), std.testing.allocator);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    app.local_workflow.commit_panel.paste(" edited");
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("Draft subject edited", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.changes.status.text());
}

test "finishCommitMessageAssist ignores generated draft after edit then clear" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.local_workflow.commit_panel.insert('x');
    app.local_workflow.commit_panel.backspace();
    try std.testing.expect(app.local_workflow.commit_panel.draftIsEmpty());
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("generated commit message ignored; draft changed", app.pages.changes.status.text());
}

test "finishCommitMessageAssist ignores improved draft after edit then restore" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.paste("Draft subject");
    const snapshot = try workflow_local.testing.buildDraftSnapshot(app.localWorkflow(), std.testing.allocator);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    app.local_workflow.commit_panel.insert('x');
    app.local_workflow.commit_panel.backspace();
    try std.testing.expectEqualStrings("Draft subject", app.local_workflow.commit_panel.subject.slice());
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("Draft subject", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.changes.status.text());
}

test "finishCommitMessageAssist ignores improved draft after close and reopen" {
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testLocalHarnessWithCommitPanel();
    defer app.local_workflow.commit_panel.deinit();

    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.paste("Draft subject");
    const snapshot = try workflow_local.testing.buildDraftSnapshot(app.localWorkflow(), std.testing.allocator);
    const launch_revision = app.local_workflow.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.local_workflow.commit_panel.close();
    app.local_workflow.commit_panel.open(.commit);
    app.local_workflow.commit_panel.paste("Draft subject");
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.localWorkflow().finishCommitMessageAssist(ctx.allocator(), finished);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("Draft subject", app.local_workflow.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.changes.status.text());
}

test "resolveCommitMessageAction resolves minimal configs and reports missing or multiple" {
    var missing = testLocalHarnessWithCommitPanel();
    defer missing.local_workflow.commit_panel.deinit();
    try std.testing.expectError(error.Missing, workflow_local.testing.resolveGenerateCommitMessageAction(missing.localWorkflow()));
    try std.testing.expectError(error.Missing, workflow_local.testing.resolveImproveCommitMessageAction(missing.localWorkflow()));

    var multiple = testLocalHarnessWithCommitPanel();
    defer multiple.local_workflow.commit_panel.deinit();
    var action: config_mod.ExternalActionConfig = .{};
    action.id = "commit-message-a";
    action.argv[0] = "helper";
    action.argv_len = 1;
    action.stdin = .staged_diff;
    var other = action;
    other.id = "commit-message-b";
    multiple.user_config.actions.items[0] = action;
    multiple.user_config.actions.len = 1;
    try std.testing.expectEqualStrings(
        "commit-message-a",
        (try workflow_local.testing.resolveGenerateCommitMessageAction(multiple.localWorkflow())).id,
    );

    multiple.user_config.actions.items[1] = other;
    multiple.user_config.actions.len = 2;
    try std.testing.expectError(error.Multiple, workflow_local.testing.resolveGenerateCommitMessageAction(multiple.localWorkflow()));

    multiple.user_config.actions.items[0].stdin = .commit_message_context;
    multiple.user_config.actions.items[1].stdin = .commit_message_context;
    try std.testing.expectError(error.Multiple, workflow_local.testing.resolveImproveCommitMessageAction(multiple.localWorkflow()));
    multiple.user_config.actions.len = 1;
    try std.testing.expectEqualStrings(
        "commit-message-a",
        (try workflow_local.testing.resolveImproveCommitMessageAction(multiple.localWorkflow())).id,
    );
}

test "selectedSidebarActionTarget resolves status-only path without loaded diff" {
    var app: LocalHarness = .{
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
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const target = app.changesOperations().selectedSidebarActionTarget() orelse return error.ExpectedActionTarget;
    try std.testing.expectEqual(git_ops.TargetKind.file, target.kind);
    try std.testing.expectEqualStrings("src/new.zig", target.path);
}

test "selectedStageToggleOperation resolves directory operation from descendants" {
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 0 },
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
    acceptTestSource(&app);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00A  src/b\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);
    switch (app.changesOperations().toggleStageTarget()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedDirectoryToggleStage,
    }

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/a\x00M  src/b\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_bundle);
    switch (app.changesOperations().toggleStageTarget()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.unstage, operation),
        else => return error.ExpectedDirectoryToggleUnstage,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU src/a\x00");
    try app.pages.changes.git_status.replace("/repo", &conflict_bundle);
    switch (app.changesOperations().toggleStageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqual(TargetKind.directory, target.kind);
            try std.testing.expectEqualStrings("src", target.path);
        },
        else => return error.ExpectedDirectoryToggleConflict,
    }
}

test "selectedHunkUnstageTarget requires a visible session-staged hunk" {
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
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
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);
    acceptTestSource(&app);

    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedHunk,
    }

    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 0);
    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.patch.len > 0);
            try std.testing.expect(target.session_mark_mutation == .remove);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }

    app.pages.changes.viewer.diff_scroll = 100;
    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .offscreen_cursor => {},
        else => return error.ExpectedOffscreenHunkUnstageTarget,
    }
}

test "projected hunk actions route through original cached and unstaged origins" {
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
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
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);
    acceptTestSource(&app);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.unstage, operation),
        else => return error.ExpectedProjectedToggleUnstage,
    }
    switch (app.changesOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedProjectedHunk,
    }
    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expectEqual(SessionHunkMarkMutation.none, target.session_mark_mutation);
        },
        else => return error.ExpectedReadyProjectedUnstage,
    }

    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedProjectedToggleStage,
    }
    switch (app.changesOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 1), target.hunk_index);
            try std.testing.expectEqual(SessionHunkMarkMutation.none, target.session_mark_mutation);
        },
        else => return error.ExpectedReadyProjectedStage,
    }
    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedProjectedHunk,
    }

    // Stage chrome and patch authority are separate contracts. A corrupt or
    // cross-generation-mismatched action origin must fail closed without
    // changing the fresh stage-state decision shown by the toggle UI.
    const live = app.changesNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    @constCast(live.hunkActionOrigins())[1] = .{ .cached = 0 };
    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedProjectedToggleStage,
    }
    switch (app.changesOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .no_hunk => {},
        else => return error.ExpectedMismatchedActionOriginToFailClosed,
    }

    @constCast(&live.authority.status_snapshot_revision).* +%= 1;
    try std.testing.expect(app.changesOperations().selectedHunkToggleOperation() == .stale_status);
}

test "hunk stage presentation keeps fresh staged authority without clearing action marks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 10 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.changes.git_status.deinit();
    acceptTestSource(&app);

    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 0);
    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_bundle);
    const presentation = try app.changesNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(presentation == .all_staged);

    switch (app.changesOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }
}

test "hunk action results mutate session staged marks" {
    const allocator = std.testing.allocator;
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.staged_hunks.deinit(allocator);
    acceptTestSource(&app);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);
    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);

    const stage_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try finishStageHunkForTest(&app, &ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .{ .add = mark_key },
        .result = .ok,
    });

    try std.testing.expect(app.pages.changes.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.staged_hunks.items.items.len);

    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try finishUnstageHunkForTest(&app, &ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .{ .remove = mark_key },
        .result = .ok,
    });

    try std.testing.expect(!app.pages.changes.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.staged_hunks.items.items.len);
}

test "hunk action none effect reloads status without adding a session mark" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    activateTestChanges(&app);
    defer app.pages.changes.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try finishStageHunkForTest(&app, &ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.changes.status_load.isPending());
}

test "hunk action none effect reloads status without removing a session mark" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    activateTestChanges(&app);
    defer app.pages.changes.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);
    try app.pages.changes.staged_hunks.addExact(allocator, roots.a, "a", mark_key);
    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try finishUnstageHunkForTest(&app, &ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    try std.testing.expect(app.pages.changes.staged_hunks.containsExact(roots.a, "a", mark_key));
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.changes.status_load.isPending());
}

test "cached projection hunk unstage reload decision travels with task result" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    activateTestChanges(&app);
    defer app.pages.changes.deinit(allocator);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);
    try app.pages.changes.staged_hunks.addExact(allocator, roots.a, "a", mark_key);
    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try finishUnstageHunkForTest(&app, &ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .reload_after_success = true,
        .result = .ok,
    });

    try std.testing.expect(app.pages.changes.staged_hunks.containsExact(roots.a, "a", mark_key));
    switch (app.pages.changes.load.pending orelse return error.ExpectedReloadAfterCachedHunkUnstage) {
        .diff_load => {},
        .repo_discovery => return error.ExpectedReloadAfterCachedHunkUnstage,
    }
    try std.testing.expectEqual(@as(usize, 3), ctx._pending_tasks_with[0..ctx._pending_tasks_with_len].len);
}

test "directory stage target uses sidebar cursor and status subtree" {
    var app: LocalHarness = .{
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
                .viewer = .{
                    // The diff pane still points at a file, but the sidebar cursor is
                    // on the directory. Directory actions must use the cursor target.
                    .selected_target = .{ .diff_file = 1 },
                    .selected_node = 0,
                },
            },
        },
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

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00M  other.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    switch (app.changesOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryStageTarget,
    }

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00");
    try app.pages.changes.git_status.replace("/repo", &staged_bundle);
    switch (app.changesOperations().stageTarget()) {
        .no_stageable_content => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedNoDirectoryStageableContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00UU src/b\x00");
    try app.pages.changes.git_status.replace("/repo", &conflict_bundle);
    switch (app.changesOperations().stageTarget()) {
        .conflict_unsupported => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedDirectoryConflictStageReject,
    }
}

test "directory unstage target scans staged subtree" {
    var app: LocalHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
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
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00AM src/b\x00 M other.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    switch (app.changesOperations().unstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryUnstageTarget,
    }

    var unstaged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00");
    try app.pages.changes.git_status.replace("/repo", &unstaged_bundle);
    switch (app.changesOperations().unstageTarget()) {
        .no_staged_content => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedNoDirectoryStagedContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00UU src/b\x00");
    try app.pages.changes.git_status.replace("/repo", &conflict_bundle);
    switch (app.changesOperations().unstageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryConflictUnstageReject,
    }
}

test "stage unstage and discard launch typed action cursor owners with task generations" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: LocalHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.changesNavigation().clearActionCursor(allocator);
    acceptTestSource(&app);
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator };

    var stageable = try git_status.StatusBundle.parseOwned(allocator, " M src/a\x00?? src/b\x00");
    try app.pages.changes.git_status.replace(roots.a, &stageable);
    try app.localWorkflow().stageSelectedFile(&ctx);
    const stage_pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedStageAction;
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, stage_pending.kind);
    try std.testing.expectEqual(stage_pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.directory, app.pages.changes.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src", app.pages.changes.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());

    var staged = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
    try app.pages.changes.git_status.replace(roots.a, &staged);
    try app.localWorkflow().unstageSelectedFile(&ctx);
    const unstage_pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedUnstageAction;
    try std.testing.expectEqual(app_actions.ActionKind.unstage_file, unstage_pending.kind);
    try std.testing.expectEqual(unstage_pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.directory, app.pages.changes.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src", app.pages.changes.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());

    app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src/a"),
    };
    app.overlay.openDiscardFile();
    try app.localWorkflow().confirmDiscardFile(&ctx);
    const discard_pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedDiscardAction;
    try std.testing.expectEqual(app_actions.ActionKind.discard_file, discard_pending.kind);
    try std.testing.expectEqual(discard_pending.generation, app.pages.changes.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(changes_page.action_cursor.TargetKind.file, app.pages.changes.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src/a", app.pages.changes.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "fresh status-only targets fail closed without accepted source" {
    const allocator = std.testing.allocator;
    var app: LocalHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "AM src/main.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try app.changesReload().createStatusOnlyLoadedSession(allocator, app.pages.changes.git_status.document);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);

    try std.testing.expectEqual(git_ops.StageTargetResult.stale_source, app.changesOperations().stageTarget());
    try std.testing.expectEqual(git_ops.UnstageTargetResult.stale_source, app.changesOperations().unstageTarget());
    try std.testing.expectEqual(git_ops.DiscardTargetResult.stale_source, app.changesOperations().discardTarget());
}

test "queued commit-message assist retains staged diff and external cwd across path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "slot", .default_dir);
    try tmp.dir.createDir(io, "replacement", .default_dir);
    var accepted = try tmp.dir.openDir(io, "slot", .{});
    defer accepted.close(io);
    var replacement = try tmp.dir.openDir(io, "replacement", .{});
    defer replacement.close(io);

    try runLocalTestGit(io, accepted, &.{ "git", "init", "--initial-branch=main" });
    try accepted.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runLocalTestGit(io, accepted, &.{ "git", "add", "base.txt" });
    try runLocalTestGit(io, accepted, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try accepted.writeFile(io, .{ .sub_path = "a-staged.txt", .data = "A_STAGED\n" });
    try runLocalTestGit(io, accepted, &.{ "git", "add", "a-staged.txt" });

    try runLocalTestGit(io, replacement, &.{ "git", "init", "--initial-branch=main" });
    try replacement.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try runLocalTestGit(io, replacement, &.{ "git", "add", "base.txt" });
    try runLocalTestGit(io, replacement, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try replacement.writeFile(io, .{ .sub_path = "b-staged.txt", .data = "B_STAGED\n" });
    try runLocalTestGit(io, replacement, &.{ "git", "add", "b-staged.txt" });
    const b_index_before = try localTestGitOutput(io, replacement, &.{ "git", "diff", "--cached", "--name-only" });
    defer allocator.free(b_index_before);

    const slot_path = try tmp.dir.realPathFileAlloc(io, "slot", allocator);
    defer allocator.free(slot_path);
    const slot_git_dir = try std.fs.path.join(allocator, &.{ slot_path, ".git" });
    defer allocator.free(slot_git_dir);
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("GIT_DIR", slot_git_dir);
    try parent_environment.put("GIT_WORK_TREE", slot_path);

    var app: LocalHarness = .{
        .allocator = allocator,
        .env_map = &parent_environment,
        .repo_session = .{ .repo_state = .{
            .discovery = try testSingleRepoDiscovery(allocator, slot_path),
            .root = try repo_root_capability.RootCapability.openCanonical(slot_path),
        } },
        .local_workflow = workflow_local.LocalState.init(allocator),
    };
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    defer app.local_workflow.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "A  a-staged.txt\x00");
    try app.pages.changes.git_status.replace(slot_path, &status_bundle);
    app.pages.changes.status_load.markSuccess();
    app.pages.changes.branch_status_load.markSuccess();
    acceptTestSource(&app);
    app.local_workflow.commit_panel.open(.commit);

    var action: config_mod.ExternalActionConfig = .{};
    action.id = "commit-message";
    action.argv[0] = "sh";
    action.argv[1] = "-c";
    action.argv[2] = "pwd > child-cwd; printf '%s' \"$1\" > display-root; cat > stdin.json; printf marker > cwd-marker; printf 'Generated from A\\n'";
    action.argv[3] = "helper";
    action.argv[4] = "{repo_root}";
    action.argv_len = 5;
    action.stdin = .staged_diff;
    app.user_config.actions.items[0] = action;
    app.user_config.actions.len = 1;

    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.localWorkflow().assistCommitMessage(&ctx);
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);

    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);
    const physical_a_path = try tmp.dir.realPathFileAlloc(io, "physical-a", allocator);
    defer allocator.free(physical_a_path);

    const message = queued[0].run(queued[0].ctx, allocator, io);
    switch (message) {
        .action_finished => |finished| switch (finished) {
            .assist_commit_message => |result| app.localWorkflow().finishCommitMessageAssist(allocator, result),
            else => return error.ExpectedCommitMessageAssist,
        },
        else => return error.ExpectedCommitMessageAssist,
    }

    const captured_json = try tmp.dir.readFileAlloc(io, "physical-a/stdin.json", allocator, .limited(1024 * 1024));
    defer allocator.free(captured_json);
    try std.testing.expect(std.mem.indexOf(u8, captured_json, "A_STAGED") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured_json, "B_STAGED") == null);
    try std.testing.expect(std.mem.indexOf(u8, captured_json, slot_path) != null);
    const display_root = try tmp.dir.readFileAlloc(io, "physical-a/display-root", allocator, .limited(4096));
    defer allocator.free(display_root);
    try std.testing.expectEqualStrings(slot_path, display_root);
    const child_cwd = try tmp.dir.readFileAlloc(io, "physical-a/child-cwd", allocator, .limited(4096));
    defer allocator.free(child_cwd);
    try std.testing.expectEqualStrings(physical_a_path, std.mem.trim(u8, child_cwd, "\r\n"));
    try tmp.dir.access(io, "physical-a/cwd-marker", .{});

    inline for (.{ "stdin.json", "display-root", "child-cwd", "cwd-marker" }) |name| {
        try std.testing.expectError(error.FileNotFound, replacement.access(io, name, .{}));
    }
    const b_index_after = try localTestGitOutput(io, replacement, &.{ "git", "diff", "--cached", "--name-only" });
    defer allocator.free(b_index_after);
    try std.testing.expectEqualStrings(b_index_before, b_index_after);
    const b_contents = try replacement.readFileAlloc(io, "b-staged.txt", allocator, .limited(4096));
    defer allocator.free(b_contents);
    try std.testing.expectEqualStrings("B_STAGED\n", b_contents);
    try std.testing.expectEqualStrings("Generated from A", app.local_workflow.commit_panel.subject.slice());
}

test "queued local Git mutation retains the accepted root across path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "slot", .default_dir);
    try tmp.dir.createDir(io, "replacement", .default_dir);
    var accepted = try tmp.dir.openDir(io, "slot", .{});
    defer accepted.close(io);
    var replacement = try tmp.dir.openDir(io, "replacement", .{});
    defer replacement.close(io);

    try runLocalTestGit(io, accepted, &.{ "git", "init", "--initial-branch=main" });
    try accepted.writeFile(io, .{ .sub_path = "a", .data = "base\n" });
    try runLocalTestGit(io, accepted, &.{ "git", "add", "a" });
    try runLocalTestGit(io, accepted, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try accepted.writeFile(io, .{ .sub_path = "a", .data = "A_MUTATION\n" });

    try runLocalTestGit(io, replacement, &.{ "git", "init", "--initial-branch=main" });
    try replacement.writeFile(io, .{ .sub_path = "a", .data = "base\n" });
    try runLocalTestGit(io, replacement, &.{ "git", "add", "a" });
    try runLocalTestGit(io, replacement, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try replacement.writeFile(io, .{ .sub_path = "a", .data = "B_MUTATION\n" });
    const b_index_before = try localTestGitOutput(io, replacement, &.{ "git", "diff", "--cached", "--name-only" });
    defer allocator.free(b_index_before);

    const slot_path = try tmp.dir.realPathFileAlloc(io, "slot", allocator);
    defer allocator.free(slot_path);
    const replacement_path = try tmp.dir.realPathFileAlloc(io, "replacement", allocator);
    defer allocator.free(replacement_path);
    const replacement_git_dir = try std.fs.path.join(allocator, &.{ replacement_path, ".git" });
    defer allocator.free(replacement_git_dir);
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("GIT_DIR", replacement_git_dir);
    try parent_environment.put("gIt_WoRk_TrEe", replacement_path);
    try parent_environment.put("GITFRAME_LOCAL_CANARY", "retained");

    var app: LocalHarness = .{
        .allocator = allocator,
        .env_map = &parent_environment,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .repo_session = .{ .repo_state = .{
            .discovery = try testSingleRepoDiscovery(allocator, slot_path),
            .root = try repo_root_capability.RootCapability.openCanonical(slot_path),
        } },
    };
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    defer app.changesNavigation().clearActionCursor(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(slot_path, &status_bundle);
    app.pages.changes.status_load.markSuccess();
    app.pages.changes.branch_status_load.markSuccess();
    acceptTestSource(&app);

    // Queue rejection must close the just-created duplicate. The next
    // duplicate reuses the same lowest free descriptor if teardown did so.
    var first_probe = try app.repoSessionView().activeCapability().?.duplicate();
    const reusable_handle = first_probe.handle;
    first_probe.deinit();
    var rejected_ctx: chasen.Ctx(LocalHarness.Msg) = .{
        ._allocator = allocator,
        ._io = io,
        ._pending_tasks_with_len = 16,
    };
    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedFile(&rejected_ctx));
    rejected_ctx._pending_tasks_with_len = 0;
    var second_probe = try app.repoSessionView().activeCapability().?.duplicate();
    try std.testing.expectEqual(reusable_handle, second_probe.handle);
    second_probe.deinit();

    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try app.localWorkflow().stageSelectedFile(&ctx);
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const Task = app_actions.StageFileTask(LocalHarness.Msg);
    const task: *Task = @ptrCast(@alignCast(queued[0].ctx));
    const task_root_observer = task.root;
    try std.testing.expect(task.root.identity.eql(app.repoSessionView().activeIdentity().?));
    try std.testing.expect(task.environment.borrow().get("GIT_DIR") == null);
    try std.testing.expect(task.environment.borrow().get("gIt_WoRk_TrEe") == null);
    try std.testing.expectEqualStrings("retained", task.environment.borrow().get("GITFRAME_LOCAL_CANARY").?);

    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);
    const message = queued[0].run(queued[0].ctx, allocator, io);
    try expectLocalRootCapabilityClosed(task_root_observer);
    switch (message) {
        .action_finished => |finished| switch (finished) {
            .stage_file => |result| try finishStageFileForTest(&app, &ctx, result),
            else => return error.ExpectedStageFileTerminal,
        },
        else => return error.ExpectedStageFileTerminal,
    }

    const a_index_after = try localTestGitOutput(io, accepted, &.{ "git", "diff", "--cached", "--name-only" });
    defer allocator.free(a_index_after);
    try std.testing.expectEqualStrings("a\n", a_index_after);
    const b_index_after = try localTestGitOutput(io, replacement, &.{ "git", "diff", "--cached", "--name-only" });
    defer allocator.free(b_index_after);
    try std.testing.expectEqualStrings(b_index_before, b_index_after);
    const b_contents = try replacement.readFileAlloc(io, "a", allocator, .limited(4096));
    defer allocator.free(b_contents);
    try std.testing.expectEqualStrings("B_MUTATION\n", b_contents);
}
