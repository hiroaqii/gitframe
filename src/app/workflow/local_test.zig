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
    const entries = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const message = entries[0].failed(error.ConcurrencyUnavailable, ctx.allocator());
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
    const revalidation = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 3), revalidation.len);
    var status_task_message = revalidation[0].failed(error.ConcurrencyUnavailable, ctx.allocator());
    defer status_task_message.deinitUndelivered(ctx.allocator());
    const status_task = status_task_message.load_finished.changes.status;
    var branch_task_message = revalidation[1].failed(error.ConcurrencyUnavailable, ctx.allocator());
    defer branch_task_message.deinitUndelivered(ctx.allocator());
    const branch_task = branch_task_message.load_finished.changes.branch_status;
    var source_task_message = revalidation[2].failed(error.ConcurrencyUnavailable, ctx.allocator());
    defer source_task_message.deinitUndelivered(ctx.allocator());
    const source_task = source_task_message.load_finished.changes.source;
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
        ._pending_tasks_len = 16,
    };
    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedHunk(&ctx));
    ctx._pending_tasks_len = 0;

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
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);

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
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);

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
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
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
    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._pending_tasks_len = 16 };

    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedHunk(&ctx));
    ctx._pending_tasks_len = 0;
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
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
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
    defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);
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
    defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);

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
    defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);

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
    defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);

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
    try std.testing.expectEqual(@as(usize, 3), ctx._pending_tasks[0..ctx._pending_tasks_len].len);
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

    var staged = try git_status.StatusBundle.parseOwned(allocator, "R  src/a\x00outside/old\x00M  src/b\x00");
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

test "Changes unstage keeps rename units and unrelated index worktree bytes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const file_tree = @import("../../file_tree.zig");
    const Case = enum { file, edited, incoming, same_directory, outgoing, repository, special, locked };
    for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try runLocalTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
        try runLocalTestGit(io, tmp.dir, &.{ "git", "config", "core.fileMode", "true" });
        try runLocalTestGit(io, tmp.dir, &.{ "git", "config", "status.renames", "true" });
        try tmp.dir.createDirPath(io, "picked");
        try tmp.dir.createDirPath(io, "outside");
        const old = switch (case) {
            .same_directory, .outgoing => "picked/old",
            .special => ":(literal)old\t\n ",
            else => "outside/old",
        };
        const new = switch (case) {
            .outgoing => "outside/new",
            .special => "picked/new*\t\n ",
            else => "picked/new",
        };
        const base = "rename line one\nrename line two\nrename line three\nrename line four\n";
        for ([_][]const u8{ old, "picked/keep", "guard", "picked/new-other" }) |path|
            try tmp.dir.writeFile(io, .{ .sub_path = path, .data = base });
        try runLocalTestGit(io, tmp.dir, &.{ "git", "add", "--all" });
        try runLocalTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
        const head_index = try localTestGitOutput(io, tmp.dir, &.{ "git", "ls-files", "--stage", "-z" });
        defer allocator.free(head_index);
        try tmp.dir.writeFile(io, .{ .sub_path = "guard", .data = "guard index\n" });
        try runLocalTestGit(io, tmp.dir, &.{ "chmod", "+x", "guard" });
        try runLocalTestGit(io, tmp.dir, &.{ "git", "add", "--", "guard" });
        try tmp.dir.writeFile(io, .{ .sub_path = "guard", .data = "guard worktree\n" });
        const guarded_index = try localTestGitOutput(io, tmp.dir, &.{ "git", "ls-files", "--stage", "-z" });
        defer allocator.free(guarded_index);
        try runLocalTestGit(io, tmp.dir, &.{ "git", "--literal-pathspecs", "mv", "--", old, new });
        if (case == .edited) {
            try tmp.dir.writeFile(io, .{ .sub_path = new, .data = base ++ "staged edit\n" });
            try runLocalTestGit(io, tmp.dir, &.{ "git", "--literal-pathspecs", "add", "--", new });
            try tmp.dir.writeFile(io, .{ .sub_path = new, .data = "different worktree bytes\n" });
        }
        const renamed_index = try localTestGitOutput(io, tmp.dir, &.{ "git", "ls-files", "--stage", "-z" });
        defer allocator.free(renamed_index);
        const directory = case == .incoming or case == .same_directory or case == .outgoing;
        if (directory) {
            try tmp.dir.writeFile(io, .{ .sub_path = "picked/keep", .data = "selected index\n" });
            try runLocalTestGit(io, tmp.dir, &.{ "git", "add", "--", "picked/keep" });
            try tmp.dir.writeFile(io, .{ .sub_path = "picked/keep", .data = "selected worktree\n" });
        }
        // Repository-wide unstage must also remove intent-to-add entries.
        try tmp.dir.writeFile(io, .{ .sub_path = "intent", .data = "untracked bytes\n" });
        if (case == .repository) try runLocalTestGit(io, tmp.dir, &.{ "git", "add", "-N", "--", "intent" });
        const expected_index = if (case == .repository) head_index else if (case == .outgoing or case == .locked) renamed_index else guarded_index;
        const raw_index_before = try tmp.dir.readFileAlloc(io, ".git/index", allocator, .limited(64 * 1024));
        defer allocator.free(raw_index_before);
        const worktree_paths = [_][]const u8{ new, "picked/keep", "guard", "picked/new-other", "intent" };
        var worktree: [worktree_paths.len][]u8 = undefined;
        var modes: [worktree_paths.len]std.Io.File.Permissions = undefined;
        for (worktree_paths, 0..) |path, i| {
            worktree[i] = try tmp.dir.readFileAlloc(io, path, allocator, .limited(4096));
            modes[i] = (try tmp.dir.statFile(io, path, .{})).permissions;
        }
        defer for (worktree) |bytes| allocator.free(bytes);

        const repo_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(repo_path);
        const raw_status = try localTestGitOutput(io, tmp.dir, &.{ "git", "status", "--porcelain=v1", "-z" });
        defer allocator.free(raw_status);
        var status = try git_status.StatusBundle.parseOwned(allocator, raw_status);
        defer status.deinit();
        const rename = for (status.document.entries) |entry| {
            if (std.mem.eql(u8, entry.path, new)) break entry;
        } else return error.ExpectedRenameEntry;
        try std.testing.expectEqual(git_status.StatusCode.renamed, rename.index);
        try std.testing.expectEqualStrings(old, rename.old_path.?);
        var arena = std.heap.ArenaAllocator.init(allocator);
        var loaded = app_test_support.loadedDiffOne();
        loaded.document = .{ .files = &.{} };
        loaded.file_text_eligibility = &.{};
        loaded.tree = try file_tree.buildWithOptions(arena.allocator(), loaded.document, status.document, .{ .root = .{ .name = "repo" } });
        var selected: ?usize = null;
        for (loaded.tree.nodes, 0..) |node, i| {
            const matches = if (case == .repository) node.kind == .repo_root else if (directory)
                node.kind == .directory and std.mem.eql(u8, node.path, "picked")
            else
                node.kind == .file and std.mem.eql(u8, node.path_key, new);
            if (matches) selected = i;
        }
        var app: LocalHarness = .{
            .allocator = allocator,
            .config = .{ .source = .unstaged },
            .pages = .{ .changes = .{
                .load = app_test_support.loadStateWithArena(arena, loaded),
                .viewer = .{ .selected_node = selected.? },
            } },
            .repo_session = .{ .repo_state = .{
                .discovery = try testSingleRepoDiscovery(allocator, repo_path),
                .root = try repo_root_capability.RootCapability.openCanonical(repo_path),
            } },
        };
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.changes.deinit(allocator);
        try app.pages.changes.git_status.replace(repo_path, &status);
        app.pages.changes.status_load.markSuccess();
        app.pages.changes.branch_status_load.markSuccess();
        acceptTestSource(&app);
        var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._io = io };
        defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);
        try app.localWorkflow().unstageSelectedFile(&ctx);
        const queued = ctx.takePendingTasks();
        try std.testing.expectEqual(@as(usize, 1), queued.len);
        // Both the owned proposal and borrowed status may disappear before execution.
        app.changesReload().clearLoadedDiff(allocator);
        app.pages.changes.git_status.deinit();
        if (case == .locked) try tmp.dir.writeFile(io, .{ .sub_path = ".git/index.lock", .data = "locked\n" });
        const message = try queued[0].run(allocator, io);
        const finished = message.action_finished.unstage_file;
        try std.testing.expect(if (case == .locked) finished.result == .failed else finished.result == .ok);
        const intent = app.localWorkflow().finishUnstageFile(allocator, finished);
        if (case == .locked) {
            try std.testing.expect(intent == null);
            try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        } else {
            try std.testing.expect(intent.?.active_matches);
            try std.testing.expectEqual(changes_action_fence.ReloadIntent.source_and_aux, intent.?.reload);
        }
        const actual_index = try localTestGitOutput(io, tmp.dir, &.{ "git", "ls-files", "--stage", "-z" });
        defer allocator.free(actual_index);
        try std.testing.expectEqualStrings(expected_index, actual_index);
        if (case == .locked) {
            const raw_index_after = try tmp.dir.readFileAlloc(io, ".git/index", allocator, .limited(64 * 1024));
            defer allocator.free(raw_index_after);
            try std.testing.expectEqualStrings(raw_index_before, raw_index_after);
        }
        // Resolve actual index OIDs to bytes, without interpreting raw names as rev syntax.
        for ([_][]const u8{ if (case == .outgoing or case == .locked) new else old, "guard" }) |path| {
            const record = try localTestGitOutput(io, tmp.dir, &.{ "git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", path });
            defer allocator.free(record);
            var fields = std.mem.tokenizeAny(u8, record, " \t");
            _ = fields.next().?;
            const blob = try localTestGitOutput(io, tmp.dir, &.{ "git", "cat-file", "blob", fields.next().? });
            defer allocator.free(blob);
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, path, "guard") and case != .repository) "guard index\n" else base, blob);
        }
        for (worktree_paths, 0..) |path, i| {
            const bytes = try tmp.dir.readFileAlloc(io, path, allocator, .limited(4096));
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings(worktree[i], bytes);
            try std.testing.expectEqual(modes[i], (try tmp.dir.statFile(io, path, .{})).permissions);
        }
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, old, .{}));
    }
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
        ._pending_tasks_len = 16,
    };
    try std.testing.expectError(error.TaskLimitExceeded, app.localWorkflow().stageSelectedFile(&rejected_ctx));
    rejected_ctx._pending_tasks_len = 0;
    var second_probe = try app.repoSessionView().activeCapability().?.duplicate();
    try std.testing.expectEqual(reusable_handle, second_probe.handle);
    second_probe.deinit();

    var ctx: chasen.Ctx(LocalHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    defer chasen.testing.discardPendingTasks(LocalHarness.Msg, &ctx);
    try app.localWorkflow().stageSelectedFile(&ctx);
    const queued = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);
    const message = try queued[0].run(allocator, io);
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
