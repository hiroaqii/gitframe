//! Owner-local contract tests for Changes read coordination.
//!
//! The harness composes only Changes page state, repository identity, action
//! fence state, and redraw outputs. It deliberately does not import or model
//! the root `App` dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../../actions.zig");
const action_lifecycle = @import("../../workflow/action_lifecycle.zig");
const app_auto_reload = @import("../../auto_reload.zig");
const diff_surface = @import("../../diff_surface.zig");
const changes_authority = @import("../../diff_surface/authority.zig");
const git_ops = @import("../../git_ops.zig");
const app_load = @import("../../load.zig");
const app_load_state = @import("../../load_state.zig");
const app_message = @import("../../message.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const app_changes_projection = @import("../../changes_projection.zig");
const app_projection_component = @import("../../projection_component.zig");
const app_shell_layout = @import("../../shell_layout.zig");
const app_test_support = @import("../../test_support.zig");
const changes_page = @import("../changes.zig");
const changes_action_fence = @import("action_fence.zig");
const changes_message = @import("message.zig");
const changes_navigation = @import("navigation.zig");
const changes_operations = @import("operations.zig");
const changes_read = @import("read_coordinator.zig");
const changes_reload = @import("reload.zig");
const changes_update = @import("update.zig");
const content_selection = @import("../../diff_surface/selection.zig");

const content_fingerprint = @import("../../../content_fingerprint.zig");
const context = @import("../../../context.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_presentation_identity = @import("../../../diff/presentation_identity.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const git_status = @import("../../../git/status.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const EmptyReason = app_load_state.EmptyReason;
const LoadedDiff = loaded_diff.LoadedDiff;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(app_message.Msg);
const BranchStatusLoadFinished = app_load.BranchStatusLoadFinished;
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const ChangesProjectionFinished = app_load.ChangesProjectionFinished;
const ChangesProjectionTask = app_load.ChangesProjectionTask(app_message.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(app_message.Msg);
const ToggleStageOperation = git_ops.ToggleStageOperation;

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

fn runChangesTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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

const ReadPages = struct {
    changes: changes_page.ChangesPageState = .{},
};

const ReadConfig = struct {
    source: diff_source.SourceMode = .unstaged,
};

const RedrawPlan = struct {
    skip_requested: bool = false,
    frame_required: bool = false,

    fn resolvesToSkip(self: RedrawPlan) bool {
        return self.skip_requested and !self.frame_required;
    }
};

const ChangesActivationHarness = struct {
    changes: *changes_page.ChangesPageState,
    repo: repo_session.View,
    source: diff_source.SourceMode,

    fn activateChanges(self: ChangesActivationHarness) u64 {
        const source_member: changes_authority.MemberFreshness = .pending;
        const auxiliary: changes_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(self.source) and self.repo.activeRoot() != null)
            .pending
        else
            .unavailable;
        return self.changes.activation.activate(self.repo.epoch(), source_member, auxiliary, auxiliary);
    }
};

const ReadHarness = struct {
    pub const Msg = app_message.Msg;

    active_page: page.Id = .changes,
    repo_session: repo_session.State = .{},
    pages: ReadPages = .{},
    config: ReadConfig = .{},
    allocator: ?std.mem.Allocator = std.testing.allocator,
    env_map: ?*std.process.Environ.Map = null,
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    redraw_plan: RedrawPlan = .{},
    action_runtime: action_lifecycle.ActionRuntime = .{},

    fn repoSessionView(self: *const ReadHarness) repo_session.View {
        return self.repo_session.view();
    }

    fn bodyLayout(self: *const ReadHarness) diff_surface.Layout {
        const body = app_shell_layout.compute(
            self.terminal_size,
            .{ .page_bar_visible = true },
        ).bodySize();
        return .{ .width = body.width, .height = body.height };
    }

    fn pageCoordinator(self: *ReadHarness) ChangesActivationHarness {
        return .{
            .changes = &self.pages.changes,
            .repo = self.repoSessionView(),
            .source = self.config.source,
        };
    }

    fn changesNavigation(self: *ReadHarness) changes_navigation.Controller {
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

    fn changesNavigationView(self: *const ReadHarness) changes_navigation.View {
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
        };
    }

    fn changesReload(self: *ReadHarness) changes_reload.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
        };
    }

    fn changesReloadView(self: *const ReadHarness) changes_reload.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
        };
    }

    fn changesActionFence(self: *ReadHarness) changes_action_fence.Controller {
        return .{
            .read_authority = &self.pages.changes.repository_read_authority,
            .activation = &self.pages.changes.activation,
            .action_cursor = &self.pages.changes.action_cursor,
            .auto_reload = &self.pages.changes.auto_reload,
            .changes_projection = &self.pages.changes.changes_projection,
            .deferred_projection_apply = &self.pages.changes.deferred_projection_apply,
        };
    }

    fn changesRead(self: *ReadHarness) changes_read.Controller {
        return .{
            .page_state = &self.pages.changes,
            .fence = self.changesActionFence().view(),
            .active_page = self.active_page,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
            .env_map = self.env_map,
            .allocator = self.allocator,
            .redraw = .{
                .skip_requested = &self.redraw_plan.skip_requested,
                .frame_required = &self.redraw_plan.frame_required,
            },
            .shell_blockers = .{
                .action_pending = self.action_runtime.view().hasPending(),
            },
        };
    }

    fn changesOperations(self: *const ReadHarness) changes_operations.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.changes.activation.state,
        };
    }

    fn changesOperationController(self: *ReadHarness) changes_operations.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .view_state = self.changesOperations(),
        };
    }

    fn actionLifecycle(self: *ReadHarness) action_lifecycle.Controller {
        return .{
            .runtime = &self.action_runtime,
            .fence = self.changesActionFence(),
        };
    }

    fn acceptActionLaunch(self: *ReadHarness, pending: app_actions.PendingAction) void {
        _ = self.actionLifecycle().acceptSpawn(
            self.allocator orelse std.testing.allocator,
            .{ .pending = pending },
        );
    }

    fn acceptActionTerminal(self: *ReadHarness, pending: app_actions.PendingAction) bool {
        const repo_root = self.repoSessionView().activeRoot() orelse "";
        return switch (self.actionLifecycle().finishExact(
            self.allocator orelse std.testing.allocator,
            pending,
            repo_root,
            repo_root,
        )) {
            .rejected => false,
            .accepted => true,
        };
    }

    fn setChangesStatus(self: *ReadHarness, comptime fmt: []const u8, args: anytype) void {
        self.pages.changes.status.set(fmt, args);
    }
};

/// Runs only the Changes-owned portion of the shell's post-message boundary.
/// Tests call this explicitly when the contract under test spans a completion
/// and the next queued read; it is intentionally not a general App dispatcher.
fn runReadCoordinationTail(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
) !void {
    _ = app.changesRead().retireSupersededActionCursor(ctx, app.action_runtime.view().generation());
    try app.changesRead().applyDeferredSourceIfReady(ctx);
    try app.changesRead().applyDeferredProjectionIfReady(ctx);
    _ = try app.changesRead().maybeStartQueuedRevalidation(ctx);
    const queued_before_projection = app.changesRead().hasQueuedFullRevalidation();
    if (app.active_page == .changes) try app.changesRead().ensureProjection(ctx);
    if (!queued_before_projection and app.changesRead().hasQueuedFullRevalidation()) {
        _ = try app.changesRead().maybeStartQueuedRevalidation(ctx);
    }
}

fn finishOwnedChangesRead(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    message: ReadHarness.Msg,
) !void {
    const finished = switch (message) {
        .load_finished => |value| value,
        else => return error.ExpectedChangesReadCompletion,
    };
    switch (finished) {
        .changes => |changes_finished| switch (changes_finished) {
            .source => |value| try app.changesRead().finishDiffLoad(ctx.allocator(), value),
            .status => |value| try app.changesRead().finishStatusLoad(ctx.allocator(), value),
            .branch_status => |value| app.changesRead().finishBranchStatusLoad(ctx.allocator(), value),
            .projection => |value| try app.changesRead().finishProjectionLoad(ctx.allocator(), value),
            .projection_syntax => |value| app.changesRead().finishGeneratedProjectionSyntax(ctx.allocator(), value),
        },
        else => return error.ExpectedChangesReadCompletion,
    }
    try runReadCoordinationTail(app, ctx);
}

fn actionTargetsCurrentChanges(
    app: *const ReadHarness,
    repo_root: []const u8,
) bool {
    return app.active_page == .changes and
        app.pages.changes.activation.currentIdentity() != null and
        app.repoSessionView().activeRootMatches(repo_root);
}

/// Completes the exact action/fence handshake, applies an optional successful
/// Changes-local outcome, then runs the read-owned scheduling tail. A null
/// outcome represents a failed action whose only Changes consequence is cursor
/// cleanup plus any already-queued terminal fallback.
fn finishTestAction(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    pending: app_actions.PendingAction,
    repo_root: []const u8,
    outcome: ?changes_operations.AcceptedActionOutcome,
) !bool {
    const active_matches = actionTargetsCurrentChanges(app, repo_root);
    const admission = app.actionLifecycle().finishExact(
        ctx.allocator(),
        pending,
        repo_root,
        if (active_matches) repo_root else null,
    );
    switch (admission) {
        .rejected => return false,
        .accepted => {},
    }
    if (outcome) |accepted| {
        const applied = app.changesOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            accepted,
            active_matches,
        );
        try app.changesRead().applyActionOutcome(ctx, pending, active_matches, applied.reload);
    } else {
        _ = app.changesActionFence().clearMatchingActionCursor(ctx.allocator(), pending.generation);
    }
    try runReadCoordinationTail(app, ctx);
    return true;
}

fn applyChangesStateOnly(
    app: *ReadHarness,
    allocator: std.mem.Allocator,
    message: changes_message.Msg,
) !void {
    var applied = try (changes_update.Controller{
        .navigation = app.changesNavigation(),
    }).apply(allocator, message);
    defer applied.deinit(allocator);
    try std.testing.expect(applied.command == null);
    if (applied.capture_display_override) {
        try app.changesRead().captureDisplayOverride(allocator);
    }
}

fn ownTestSourceRead(app: *ReadHarness, generation: u64, kind: changes_page.ReloadKind) void {
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

fn beginAcceptedTestAction(app: *ReadHarness, kind: app_actions.ActionKind) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    const pending = app.actionLifecycle().prepare(kind).pending;
    app.acceptActionLaunch(pending);
    return pending;
}

fn installTestActionCursor(
    app: *ReadHarness,
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

fn promoteTestActionCursor(app: *ReadHarness, action_generation: u64) !void {
    return promoteTestActionCursorWithRequirement(app, action_generation, .source_and_status);
}

fn promoteTestActionCursorWithRequirement(
    app: *ReadHarness,
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

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?git_branch_status.Upstream = null,
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

fn expectGeneratedProjectionEligible(app: *const ReadHarness) !void {
    const ready = switch (app.pages.changes.changes_projection.displayed) {
        .ready => |ready| ready,
        .idle, .failed => return error.ExpectedGeneratedProjection,
    };
    const bundle = switch (ready.value) {
        .generated_added_file => |bundle| bundle,
        else => return error.ExpectedGeneratedProjection,
    };
    try std.testing.expect(bundle.decoration == .eligible);
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

const CanonicalPublicationReads = struct {
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

fn canonicalPublicationTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !ReadHarness {
    var app: ReadHarness = .{
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
) !ReadHarness {
    var app: ReadHarness = .{
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
) !ReadHarness {
    var app: ReadHarness = .{
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
    try std.testing.expect(app.changesNavigationView().displayedChangesBody() == .primary);
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

fn canonicalPublicationStagedOnlyReuseCandidate(
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
    app: *ReadHarness,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !content_selection.ContentToken {
    const displayed = app.changesNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    const token = app.changesNavigationView().currentContentToken() orelse
        return error.ExpectedContentToken;
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = if (app.changesNavigationView().effectiveDisplayMode() == .unified)
            .unified_diff
        else
            .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 1, .line_index = 0 },
        .focus = .{ .hunk_index = 1, .line_index = 0 },
        .moved = true,
    };
    app.pages.changes.completed_selection = try content_selection.buildParsedFolded(
        allocator,
        token,
        displayed,
        app.changesNavigationView().selectedFoldedHunks(),
        app.pages.changes.selection_layout_revision,
        selection,
    );
    try app.pages.changes.staged_hunks.addExact(allocator, repo_root, "a", .{
        .content = token,
        .display_hunk_index = 1,
    });
    return token;
}

fn finishCanonicalPublicationAction(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
    action: CanonicalPublicationAction,
    repo_root: []const u8,
) !void {
    const pending = beginAcceptedTestAction(app, action.actionKind());
    if (action != .commit) {
        try installTestActionCursor(app, allocator, .file, "a", pending.generation);
    }
    const outcome: changes_operations.AcceptedActionOutcome = switch (action) {
        .stage_file => .stage_file,
        .unstage_file => .unstage_file,
        .discard_file => .{ .discard_file = .{ .repo_root = repo_root, .path = "a" } },
        .commit => .{ .commit = .{ .repo_root = repo_root } },
    };
    try std.testing.expect(try finishTestAction(app, ctx, pending, repo_root, outcome));
}

fn takeCanonicalPublicationReads(
    ctx: *chasen.testing.TestCtx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    var entries = [_]chasen.testing.TestTask(ReadHarness.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
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

fn startCanonicalPublicationWatch(
    app: *ReadHarness,
    ctx: *chasen.testing.TestCtx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    try app.changesRead().autoReloadTick(&ctx.ctx);
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
    app: *const ReadHarness,
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

fn finishCanonicalPublicationStatus(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
    status_text: []const u8,
) !void {
    var status = try git_status.StatusBundle.parseOwned(allocator, status_text);
    try app.changesRead().finishStatusLoad(ctx.allocator(), .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .loaded = status },
    });
    status = undefined;
}

fn finishCanonicalPublicationStatusFailure(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
) !void {
    try app.changesRead().finishStatusLoad(ctx.allocator(), .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .failed_static = "status failed" },
    });
}

fn finishCanonicalPublicationSource(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
    reads: CanonicalPublicationReads,
    diff: []const u8,
) !void {
    try app.changesRead().finishDiffLoad(ctx.allocator(), .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, diff) },
    });
}

fn finishCanonicalPublicationEmpty(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    reads: CanonicalPublicationReads,
) !void {
    try app.changesRead().finishDiffLoad(ctx.allocator(), .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .empty,
    });
}

fn finishCanonicalPublicationBranch(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    reads: CanonicalPublicationReads,
) !void {
    app.changesRead().finishBranchStatusLoad(ctx.allocator(), .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .failed_static = "test branch status terminal" },
    });
}

fn takeCanonicalPublicationProjectionRequest(
    ctx: *chasen.testing.TestCtx(ReadHarness.Msg),
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
    app: *const ReadHarness,
    expected_hunks: [*]const diff_parser.Hunk,
) !void {
    const retained = app.changesNavigationView().activeCombinedProjection() orelse
        return error.ExpectedRetainedCanonicalPublication;
    try std.testing.expectEqual(expected_hunks, retained.displayFile().hunks.ptr);
}

fn expectRetainedOrdinaryPrimaryPublication(
    app: *const ReadHarness,
    expected_loaded: *const loaded_diff.LoadedDiff,
    expected_token: content_selection.ContentToken,
) !void {
    const primary = switch (app.changesNavigationView().displayedChangesBody()) {
        .primary => |value| value,
        else => return error.ExpectedRetainedOrdinaryPrimary,
    };
    try std.testing.expect(primary.loaded == expected_loaded);
    const token = app.changesNavigationView().currentContentToken() orelse
        return error.ExpectedContentToken;
    try std.testing.expect(token.eql(expected_token));
}

fn expectFreshCanonicalActionCapabilities(
    app: *ReadHarness,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    switch (app.changesOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (app.changesOperations().unstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.changes.viewer.diff_scroll = .{ .logical = 0 };
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.changesOperations().selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkUnstageCapability,
    }

    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (app.changesOperations().selectedHunkStageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 1), target.hunk_index);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkStageCapability,
    }
}

fn expectFreshCanonicalPublication(
    app: *ReadHarness,
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
    try std.testing.expect(request.matchesRootIdentity(app.repoSessionView().activeIdentity()));
    const expected_presentation = request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .combined_projection);
    try std.testing.expect(expected_presentation.content_token.eql(prior_content_token));

    const published = app.changesNavigationView().activeCombinedProjection() orelse
        return error.ExpectedFreshCombinedPublication;
    try std.testing.expect(published.displayFile().hunks.ptr != prior_hunks);
    try std.testing.expect(published.presentation.content_token.eql(
        diff_presentation_identity.ContentToken.init(expected_source_revision),
    ));
    try std.testing.expectEqual(
        expected_status_revision,
        published.authority.status_snapshot_revision,
    );

    const authority = app.changesNavigationView().activeHunkAuthority() orelse
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
    app: *ReadHarness,
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
    try std.testing.expect(request.matchesRootIdentity(app.repoSessionView().activeIdentity()));
    const expected_presentation = request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .combined_projection);
    try std.testing.expect(expected_presentation.content_token.eql(prior_content_token));
    try std.testing.expect(app.changesNavigationView().displayedChangesBody() == .cached);
    try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);

    switch (app.changesOperations().stageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (app.changesOperations().unstageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.changes.viewer.diff_scroll = .{ .logical = 0 };
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(
            ToggleStageOperation.unstage,
            operation,
        ),
        else => return error.ExpectedFreshHunkUnstageOperation,
    }
    switch (app.changesOperations().selectedHunkStageTarget(allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedHunk,
    }
    switch (app.changesOperations().selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkUnstageCapability,
    }
}

fn expectOrdinaryPrimaryCandidateTargetMatrix() !void {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    const SourceTerminal = enum { loaded, empty, unchanged };
    const cases = [_]struct {
        name: []const u8,
        status: []const u8,
        source: SourceTerminal,
        expected: app_changes_projection.Kind,
    }{
        .{
            .name = "mixed with source",
            .status = "MM a\x00",
            .source = .loaded,
            .expected = .combined_hunks,
        },
        .{
            .name = "mixed without source",
            .status = "MM a\x00",
            .source = .empty,
            .expected = .cached_diff,
        },
        .{
            .name = "staged only",
            .status = "M  a\x00",
            .source = .loaded,
            .expected = .cached_diff,
        },
        .{
            .name = "untracked",
            .status = "?? a\x00",
            .source = .loaded,
            .expected = .generated_added_file,
        },
    };

    for (cases) |case| {
        errdefer std.log.err("candidate target case failed: {s}", .{case.name});
        var app = try ordinaryPrimaryPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();

        try finishCanonicalPublicationAction(
            &app,
            &ctx.ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);
        try finishCanonicalPublicationStatus(
            &app,
            &ctx.ctx,
            allocator,
            roots.a,
            reads,
            case.status,
        );
        switch (case.source) {
            .loaded => try finishCanonicalPublicationSource(
                &app,
                &ctx.ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            ),
            .empty => try finishCanonicalPublicationEmpty(&app, &ctx.ctx, reads),
            .unchanged => try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
                .identity = reads.source_identity,
                .read_epoch = reads.source_read_epoch,
                .generation = reads.source_generation,
                .background_cycle_id = reads.source_cycle_id,
                .result = .{
                    .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
                },
            }),
        }

        try app.changesRead().ensureProjection(&ctx.ctx);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx);
        defer request.deinit(allocator);
        try std.testing.expectEqual(case.expected, request.kind);
        try std.testing.expectEqualStrings("a", request.path_key);
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);
    }
}

fn expectOrdinaryPrimaryNoTargetPublication(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    source_changes: bool,
) !void {
    var app = try ordinaryPrimaryPublicationTestApp(allocator, repo_root);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    app.changesNavigation().enterSearchMode();
    setDiffSearchInput(&app, "new");
    app.changesNavigation().submitSearch(std.testing.allocator);
    const search_before = app.pages.changes.search.match orelse
        return error.ExpectedSearchMatch;
    const search_offset_before = app.pages.changes.search.match_offset;
    const primary_before = switch (app.changesNavigationView().displayedChangesBody()) {
        .primary => |value| value,
        else => return error.ExpectedOrdinaryPrimary,
    };
    const owner_before = primary_before.loaded;
    const source_text_before = primary_before.loaded.text.ptr;
    const tree_nodes_before = primary_before.loaded.tree.nodes.ptr;
    const status_root_before = app.pages.changes.git_status.repo_root.?.ptr;
    const status_entries_before = app.pages.changes.git_status.document.entries.ptr;
    const token_before = try installCanonicalPublicationLineageOwners(
        &app,
        allocator,
        repo_root,
    );
    const source_revision_before = app.pages.changes.source_session_revision;
    const status_revision_before = app.pages.changes.status_snapshot_revision;
    const cursor_before = app.pages.changes.viewer.diff_cursor;
    const scroll_before = app.pages.changes.viewer.diff_scroll.row();
    const horizontal_before = app.pages.changes.viewer.diff_horizontal_scroll;
    const sidebar_horizontal_before =
        app.pages.changes.viewer.sidebar_horizontal_scroll;

    try finishCanonicalPublicationAction(
        &app,
        &ctx.ctx,
        allocator,
        .stage_file,
        repo_root,
    );
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationStatus(
        &app,
        &ctx.ctx,
        allocator,
        repo_root,
        reads,
        " M a\x00",
    );
    try expectRetainedOrdinaryPrimaryPublication(&app, owner_before, token_before);
    try std.testing.expect(
        app.pages.changes.git_status.repo_root.?.ptr == status_root_before,
    );
    try std.testing.expect(
        app.pages.changes.git_status.document.entries.ptr == status_entries_before,
    );
    try std.testing.expectEqual(
        source_revision_before,
        app.pages.changes.source_session_revision,
    );
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.changes.status_snapshot_revision,
    );
    try std.testing.expect(!app.pages.changes.status_load.isFresh());
    try std.testing.expectEqual(
        context.SelectedTarget{ .diff_file = 0 },
        app.pages.changes.viewer.selected_target.?,
    );
    try std.testing.expectEqual(cursor_before, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(
        horizontal_before,
        app.pages.changes.viewer.diff_horizontal_scroll,
    );
    try std.testing.expectEqual(
        sidebar_horizontal_before,
        app.pages.changes.viewer.sidebar_horizontal_scroll,
    );
    try std.testing.expectEqual(
        search_before.coordinate,
        app.pages.changes.search.match.?.coordinate,
    );
    try std.testing.expectEqual(
        search_offset_before,
        app.pages.changes.search.match_offset,
    );
    const retained_selection = app.pages.changes.completed_selection orelse
        return error.ExpectedRetainedCompletedSelection;
    try std.testing.expect(retained_selection.token.eql(token_before));
    try std.testing.expect(app.pages.changes.staged_hunks.containsExact(
        repo_root,
        "a",
        .{ .content = token_before, .display_hunk_index = 1 },
    ));
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(changes_read.testing.readBusy(app.changesRead()));
    try std.testing.expect(app.changesOperations().stageTarget() == .stale_source);

    if (source_changes) {
        try finishCanonicalPublicationSource(
            &app,
            &ctx.ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
    } else {
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = reads.source_identity,
            .read_epoch = reads.source_read_epoch,
            .generation = reads.source_generation,
            .background_cycle_id = reads.source_cycle_id,
            .result = .{
                .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
            },
        });
    }

    try app.changesRead().ensureProjection(&ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, repo_root, reads);

    try std.testing.expect(app.pages.changes.changes_projection.displayed == .idle);
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
    try std.testing.expect(app.pages.changes.status_load.isFresh());
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.changes.status_snapshot_revision,
    );
    try std.testing.expect(
        app.pages.changes.git_status.repo_root.?.ptr == status_root_before,
    );
    try std.testing.expect(
        app.pages.changes.git_status.document.entries.ptr == status_entries_before,
    );
    try std.testing.expectEqualStrings(
        "a",
        app.changesNavigationView().selectedStagePathKey().?,
    );
    try std.testing.expectEqual(
        context.SelectedTarget{ .diff_file = 0 },
        app.pages.changes.viewer.selected_target.?,
    );
    try std.testing.expect(app.changesReloadView().projectionTarget() == null);
    try std.testing.expectEqualStrings("new", app.pages.changes.search.query.slice());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
    switch (app.changesOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileStageCapability,
    }

    const primary_after = switch (app.changesNavigationView().displayedChangesBody()) {
        .primary => |value| value,
        else => return error.ExpectedFinalOrdinaryPrimary,
    };
    const token_after = app.changesNavigationView().currentContentToken() orelse
        return error.ExpectedContentToken;
    if (source_changes) {
        try std.testing.expect(primary_after.loaded.text.ptr != source_text_before);
        try std.testing.expectEqualStrings(
            app_test_support.diff_unstaged_projection,
            primary_after.loaded.text,
        );
        try std.testing.expectEqual(@as(usize, 1), primary_after.loaded.document.files.len);
        try std.testing.expectEqualStrings(
            "a",
            diff_file.canonicalPathKey(primary_after.loaded.document.files[0]).?,
        );
        try std.testing.expect(primary_after.loaded.tree.nodes.ptr != tree_nodes_before);
        try std.testing.expectEqual(
            source_revision_before + 1,
            app.pages.changes.source_session_revision,
        );
        try std.testing.expect(!token_after.eql(token_before));
        try std.testing.expect(app.pages.changes.completed_selection == null);
        try std.testing.expect(!app.pages.changes.staged_hunks.containsExact(
            repo_root,
            "a",
            .{ .content = token_before, .display_hunk_index = 1 },
        ));
        try std.testing.expect(app.pages.changes.search.match != null);
        try std.testing.expect(
            app.pages.changes.viewer.diff_scroll.row() <
                app.changesNavigationView().displayedDiffLineCount(),
        );
        try std.testing.expect(
            app.pages.changes.viewer.diff_horizontal_scroll <= horizontal_before,
        );
    } else {
        try std.testing.expect(primary_after.loaded == owner_before);
        try std.testing.expect(primary_after.loaded.tree.nodes.ptr == tree_nodes_before);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.changes.source_session_revision,
        );
        try std.testing.expect(token_after.eql(token_before));
        const completed = app.pages.changes.completed_selection orelse
            return error.ExpectedRetainedCompletedSelection;
        try std.testing.expect(completed.token.eql(token_before));
        try std.testing.expect(app.pages.changes.staged_hunks.containsExact(
            repo_root,
            "a",
            .{ .content = token_before, .display_hunk_index = 1 },
        ));
        try std.testing.expectEqual(cursor_before, app.pages.changes.viewer.diff_cursor);
        try std.testing.expectEqual(scroll_before, app.pages.changes.viewer.diff_scroll.row());
        try std.testing.expectEqual(
            horizontal_before,
            app.pages.changes.viewer.diff_horizontal_scroll,
        );
        try std.testing.expectEqual(
            sidebar_horizontal_before,
            app.pages.changes.viewer.sidebar_horizontal_scroll,
        );
        try std.testing.expectEqual(
            search_before.coordinate,
            app.pages.changes.search.match.?.coordinate,
        );
        try std.testing.expectEqual(
            search_offset_before,
            app.pages.changes.search.match_offset,
        );
    }
}

const cached_projection_b_diff =
    \\diff --git a/b b/b
    \\index 1..2 100644
    \\--- a/b
    \\+++ b/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\
;

fn setDiffSearchQuery(app: *ReadHarness, query: []const u8) void {
    @memcpy(app.pages.changes.search.query.buffer[0..query.len], query);
    app.pages.changes.search.query.len = query.len;
    app.pages.changes.search.query.cursor = query.len;
    setDiffSearchInput(app, query);
}

fn setDiffSearchInput(app: *ReadHarness, query: []const u8) void {
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn acceptTestSource(app: *ReadHarness) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn testSessionHunkMarkKey(source_session_revision: u64, display_hunk_index: usize) git_ops.SessionHunkMarkKey {
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

fn currentTestSessionHunkMarkKey(app: *const ReadHarness, display_hunk_index: usize) !git_ops.SessionHunkMarkKey {
    return .{
        .content = app.changesNavigationView().currentContentToken() orelse return error.ExpectedContentToken,
        .display_hunk_index = display_hunk_index,
    };
}

fn addCurrentTestSessionHunkMark(
    app: *ReadHarness,
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

fn syncTestActivation(app: *ReadHarness) void {
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

fn testCombinedHunkBundle(allocator: std.mem.Allocator) !app_changes_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection);
    errdefer cached_bundle.deinit();

    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_unstaged_projection);
    errdefer unstaged_bundle.deinit();

    var cached_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_cached_projection);
    errdefer cached_authority.deinit();
    var unstaged_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_unstaged_projection);
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

fn mutationFenceRepoTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !ReadHarness {
    var app: ReadHarness = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
    };
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    _ = app.pageCoordinator().activateChanges();
    return app;
}

fn replaceMutationFenceTestRepo(
    app: *ReadHarness,
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
    _ = app.pageCoordinator().activateChanges();
}

fn initStageHunkLaunchApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !ReadHarness {
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
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{
                .discovery = discovery,
                .root = root,
            },
        },
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

test "Changes revalidation startup retains intent through two queue rejections and scheduler acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    const epoch_before_launch = app.pages.changes.repository_read_authority.epoch;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    const epoch_advanced =
        app.pages.changes.repository_read_authority.epoch.eql(epoch_before_launch.next());
    const generation_before_terminal = app.pages.changes.load.generation;

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(16);
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx.ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;
    const generation_after_rejections = app.pages.changes.load.generation;
    ctx.discardPendingTasks();

    try runReadCoordinationTail(&app, &ctx.ctx);
    const accepted_count = ctx.pendingTaskCount();
    const generation_after_acceptance = app.pages.changes.load.generation;
    var completions: [3]ReadHarness.Msg = undefined;
    if (accepted_count == completions.len) {
        var accepted = [_]chasen.testing.TestTask(ReadHarness.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
        defer for (&accepted) |*task| task.deinit();
        for (&accepted, 0..) |*task, index| {
            completions[index] = try task.fail(error.ConcurrencyUnavailable);
        }
        for (&completions) |*completion| {
            try finishOwnedChangesRead(&app, &ctx.ctx, completion.*);
            completion.* = undefined;
        }
    } else {
        ctx.discardPendingTasks();
    }
    const duplicate_count_after_terminal = ctx.pendingTaskCount();

    try std.testing.expect(fence_closed);
    try std.testing.expect(epoch_advanced);
    try std.testing.expect(terminal_returned_normally);
    try std.testing.expectEqual(
        generation_before_terminal + 2,
        generation_after_rejections,
    );
    try std.testing.expectEqual(@as(usize, 3), accepted_count);
    try std.testing.expectEqual(
        generation_before_terminal + 3,
        generation_after_acceptance,
    );
    try std.testing.expectEqual(@as(u8, 0), duplicate_count_after_terminal);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
}

test "Changes revalidation startup lets retained intent reach manual universal acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const generation_before_terminal = app.pages.changes.load.generation;

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(16);
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx.ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;
    const generation_after_same_update_rejections = app.pages.changes.load.generation;

    // A neutral update under the same queue pressure must observe the retained
    // owner and make one more rejected scheduler attempt. An implementation
    // which pre-consumed the intent on either earlier rejection cannot satisfy
    // this generation transition merely because the later manual reload starts.
    try runReadCoordinationTail(&app, &ctx.ctx);
    const generation_after_later_rejection = app.pages.changes.load.generation;

    ctx.discardPendingTasks();
    switch (app.changesRead().prepareManualReload()) {
        .blocked => {},
        .ready => try app.changesRead().startPreparedManualReload(&ctx.ctx),
    }
    try runReadCoordinationTail(&app, &ctx.ctx);
    const accepted_count = ctx.pendingTaskCount();
    const generation_after_manual_acceptance = app.pages.changes.load.generation;
    var completions: [3]ReadHarness.Msg = undefined;
    if (accepted_count == completions.len) {
        var accepted = [_]chasen.testing.TestTask(ReadHarness.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
        defer for (&accepted) |*task| task.deinit();
        for (&accepted, 0..) |*task, index| {
            completions[index] = try task.fail(error.ConcurrencyUnavailable);
        }
        for (&completions) |*completion| {
            try finishOwnedChangesRead(&app, &ctx.ctx, completion.*);
            completion.* = undefined;
        }
    } else {
        ctx.discardPendingTasks();
    }
    const duplicate_count_after_terminal = ctx.pendingTaskCount();

    try std.testing.expect(terminal_returned_normally);
    try std.testing.expectEqual(
        generation_before_terminal + 2,
        generation_after_same_update_rejections,
    );
    try std.testing.expectEqual(
        generation_before_terminal + 3,
        generation_after_later_rejection,
    );
    try std.testing.expectEqual(@as(usize, 3), accepted_count);
    try std.testing.expectEqual(
        generation_before_terminal + 4,
        generation_after_manual_acceptance,
    );
    try std.testing.expectEqual(@as(u8, 0), duplicate_count_after_terminal);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
}

test "Changes revalidation startup drains partial auxiliaries before one replacement" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, " M old.zig\x00");
    try app.pages.changes.git_status.replace(roots.a, &old_status);
    var old_branch = try branchStatusBundleForTest(allocator, .{
        .oid = "old-oid",
        .branch = "old-branch",
    });
    try app.pages.changes.branch_status.replace(roots.a, &old_branch);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    app.pages.changes.activation.queueRevalidation();

    const saturated_slots: usize = 14;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(saturated_slots);
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx.ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;

    const accepted_tail_len = ctx.pendingTaskCount() - saturated_slots;
    var status_message: ?ReadHarness.Msg = null;
    var branch_message: ?ReadHarness.Msg = null;
    if (accepted_tail_len == 2) {
        var status_task = ctx.takeTask(saturated_slots).?;
        defer status_task.deinit();
        var branch_task = ctx.takeTask(saturated_slots).?;
        defer branch_task.deinit();
        status_message = try status_task.fail(error.ConcurrencyUnavailable);
        status_message.?.load_finished.changes.status.result = .{ .loaded = try git_status.StatusBundle.parseOwned(allocator, " M new.zig\x00") };
        branch_message = try branch_task.fail(error.ConcurrencyUnavailable);
        branch_message.?.load_finished.changes.branch_status.result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .oid = "new-oid", .branch = "new-branch" }) };
    }
    ctx.discardPendingTasks();

    if (status_message) |message| try finishOwnedChangesRead(&app, &ctx.ctx, message);
    const replacement_before_branch = ctx.pendingTaskCount();
    if (branch_message) |message| try finishOwnedChangesRead(&app, &ctx.ctx, message);
    const replacement_count = ctx.pendingTaskCount();
    const status_retained =
        app.pages.changes.git_status.document.entries.len == 1 and
        std.mem.eql(
            u8,
            app.pages.changes.git_status.document.entries[0].path,
            "old.zig",
        );
    const branch_retained =
        app.pages.changes.branch_status.status.branchName() != null and
        std.mem.eql(
            u8,
            app.pages.changes.branch_status.status.branchName().?,
            "old-branch",
        );

    try std.testing.expect(fence_closed);
    try std.testing.expect(terminal_returned_normally);
    try std.testing.expectEqual(@as(usize, 2), accepted_tail_len);
    try std.testing.expectEqual(@as(u8, 0), replacement_before_branch);
    try std.testing.expectEqual(@as(u8, 3), replacement_count);
    try std.testing.expect(status_retained);
    try std.testing.expect(branch_retained);
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
}

test "Changes revalidation startup detaches mismatched runtime failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    try replaceMutationFenceTestRepo(&app, allocator, roots.b);

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try std.testing.expect(try finishTestAction(&app, &ctx.ctx, pending, roots.a, null));

    try std.testing.expect(fence_closed);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    try std.testing.expectEqualStrings(roots.b, app.repoSessionView().activeRoot().?);
}

test "Changes revalidation startup preserves only ordinary intent after mismatch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    try replaceMutationFenceTestRepo(&app, allocator, roots.b);
    app.pages.changes.activation.queueRevalidation();

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try std.testing.expect(try finishTestAction(&app, &ctx.ctx, pending, roots.a, null));

    const entry_count = ctx.pendingTaskCount();
    try std.testing.expectEqual(@as(usize, 3), entry_count);
    var entries = [_]chasen.testing.TestTask(ReadHarness.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&entries) |*task| task.deinit();
    const current_source_root = app.repo_session.view().activeRoot();

    try std.testing.expect(fence_closed);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(current_source_root != null);
    try std.testing.expectEqualStrings(roots.b, current_source_root.?);
}

test "Changes revalidation startup retries repository discovery after detached terminal" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("gIt_retry_selector", "redirect");
    try parent_environment.put("GITFRAME_S1_CANARY", "preserved");
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.env_map = &parent_environment;

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state = .{};
    app.repo_session.repo_epoch +%= 1;
    app.pages.changes.activation.deactivate();
    _ = app.pageCoordinator().activateChanges();
    app.pages.changes.activation.queueRevalidation();

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(16);
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx.ctx,
        pending,
        roots.a,
        null,
    ) catch false;
    ctx.discardPendingTasks();

    try runReadCoordinationTail(&app, &ctx.ctx);
    const retry_count = ctx.pendingTaskCount();
    var retry_entries = ctx.takeTask(0).?;
    defer retry_entries.deinit();
    var retry_message = try retry_entries.fail(error.ConcurrencyUnavailable);
    defer retry_message.deinitUndelivered(allocator);
    try std.testing.expect(fence_closed);
    try std.testing.expect(terminal_returned_normally);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 1), retry_count);
    try std.testing.expectEqual(app.pages.changes.activation.currentIdentity().?, retry_message.load_finished.coordinator.repo_discovery.identity);
}

test "Changes revalidation startup discards inactive terminal fallback" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var inactive = try mutationFenceRepoTestApp(allocator, roots.a);
    defer inactive.pages.changes.deinit(allocator);
    defer inactive.repo_session.repo_state.deinit(allocator);
    const inactive_pending = inactive.actionLifecycle().prepare(.stage_file).pending;
    inactive.acceptActionLaunch(inactive_pending);
    const inactive_fence_closed =
        !inactive.pages.changes.repository_read_authority.mayStartRepositoryRead();
    inactive.pages.changes.activation.deactivate();
    inactive.active_page = .repository;
    var inactive_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    inactive_ctx.init(allocator, std.testing.io);
    defer inactive_ctx.deinit();
    try std.testing.expect(try finishTestAction(
        &inactive,
        &inactive_ctx.ctx,
        inactive_pending,
        roots.a,
        null,
    ));

    try std.testing.expect(inactive_fence_closed);
    try std.testing.expect(!inactive.action_runtime.view().hasPending());
    try std.testing.expect(inactive.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(usize, 0), inactive_ctx.pendingTaskCount());
}

test "Changes revalidation startup retains both intents after status-only rejection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    // Terminal-only fallback: rejecting the narrow status member must leave
    // enough authority for a later neutral scheduler opportunity to start the
    // full replacement.
    {
        var app = try initStageHunkLaunchApp(allocator, roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.changes.deinit(allocator);

        const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
        try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
        app.acceptActionLaunch(pending);
        const fence_closed =
            !app.pages.changes.repository_read_authority.mayStartRepositoryRead();

        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        try ctx.fillTaskSlots(16);
        const terminal_returned_normally = finishTestAction(
            &app,
            &ctx.ctx,
            pending,
            roots.a,
            .{ .stage_hunk = .{
                .repo_root = roots.a,
                .path = "a",
                .hunk_index = 0,
                .session_mark_mutation = .none,
            } },
        ) catch false;
        ctx.discardPendingTasks();

        try runReadCoordinationTail(&app, &ctx.ctx);
        const later_full_count = ctx.pendingTaskCount();

        try std.testing.expect(fence_closed);
        try std.testing.expect(terminal_returned_normally);
        try std.testing.expectEqual(@as(u8, 3), later_full_count);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    }

    // Ordinary + terminal: the existing ordinary scalar is direct evidence
    // that status rejection consumed neither class. The terminal-only case
    // above supplies the independent evidence for the second scalar.
    {
        var app = try initStageHunkLaunchApp(allocator, roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.changes.deinit(allocator);

        const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
        try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
        app.acceptActionLaunch(pending);
        app.pages.changes.activation.queueRevalidation();
        const activation_id = app.pages.changes.activation.next_activation_id;

        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        try ctx.fillTaskSlots(16);
        const terminal_returned_normally = finishTestAction(
            &app,
            &ctx.ctx,
            pending,
            roots.a,
            .{ .stage_hunk = .{
                .repo_root = roots.a,
                .path = "a",
                .hunk_index = 0,
                .session_mark_mutation = .none,
            } },
        ) catch false;
        const ordinary_retained =
            app.pages.changes.activation.revalidation_requested == activation_id;
        ctx.discardPendingTasks();

        try runReadCoordinationTail(&app, &ctx.ctx);
        const later_full_count = ctx.pendingTaskCount();

        try std.testing.expect(terminal_returned_normally);
        try std.testing.expect(ordinary_retained);
        try std.testing.expectEqual(@as(u8, 3), later_full_count);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    }
}

test "Changes revalidation startup keeps ordinary full intent after status-only acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.changes.repository_read_authority.mayStartRepositoryRead();
    app.pages.changes.activation.queueRevalidation();

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try std.testing.expect(try finishTestAction(
        &app,
        &ctx.ctx,
        pending,
        roots.a,
        .{ .stage_hunk = .{
            .repo_root = roots.a,
            .path = "a",
            .hunk_index = 0,
            .session_mark_mutation = .none,
        } },
    ));
    const status_only_count = ctx.pendingTaskCount();
    var status_terminal: ?ReadHarness.Msg = null;
    if (status_only_count == 1) {
        var task = ctx.takeTask(0).?;
        defer task.deinit();
        status_terminal = try task.fail(error.ConcurrencyUnavailable);
    } else {
        ctx.discardPendingTasks();
    }
    if (status_terminal) |message| try finishOwnedChangesRead(&app, &ctx.ctx, message);
    const full_count_after_status_terminal = ctx.pendingTaskCount();

    try std.testing.expect(fence_closed);
    try std.testing.expectEqual(@as(usize, 1), status_only_count);
    try std.testing.expectEqual(@as(u8, 3), full_count_after_status_terminal);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
}

test "status-only hunk refresh ignores stale completion and closes on exact runtime failure" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .allocator = allocator,
        .pages = .{ .changes = .{
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
    };
    defer app.pages.changes.deinit(allocator);
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "stale failure" },
    });
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "read task spawn failure rejects status branch and projection page state" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var status_app: ReadHarness = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    status_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer status_app.repo_session.repo_state.deinit(allocator);
    _ = status_app.pageCoordinator().activateChanges();
    var status_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    status_ctx.init(allocator, std.testing.io);
    defer status_ctx.deinit();
    try status_ctx.fillTaskSlots(16);
    try std.testing.expectError(
        error.TaskLimitExceeded,
        changes_read.testing.startStatusLoadTracked(status_app.changesRead(), &status_ctx.ctx, roots.a, .foreground, null, null),
    );
    status_ctx.discardPendingTasks();
    try std.testing.expect(status_app.pages.changes.status_load.pending == null);
    try std.testing.expectEqualStrings("could not start status load task", status_app.pages.changes.status.text());

    var branch_app: ReadHarness = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    branch_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer branch_app.repo_session.repo_state.deinit(allocator);
    _ = branch_app.pageCoordinator().activateChanges();
    var branch_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    branch_ctx.init(allocator, std.testing.io);
    defer branch_ctx.deinit();
    try branch_ctx.fillTaskSlots(16);
    _ = changes_read.testing.startBranchStatusLoad(branch_app.changesRead(), &branch_ctx.ctx, roots.a, null);
    branch_ctx.discardPendingTasks();
    try std.testing.expect(branch_app.pages.changes.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not start branch status load task", branch_app.pages.changes.status.text());

    var projection_app: ReadHarness = .{
        .allocator = allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    projection_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer projection_app.repo_session.repo_state.deinit(allocator);
    _ = projection_app.pageCoordinator().activateChanges();
    defer projection_app.changesReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.changes.git_status.deinit();
    var staged = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try projection_app.pages.changes.git_status.replace(roots.a, &staged);
    var projection_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    projection_ctx.init(allocator, std.testing.io);
    defer projection_ctx.deinit();
    try projection_ctx.fillTaskSlots(16);
    try std.testing.expectError(error.TaskLimitExceeded, projection_app.changesRead().ensureProjection(&projection_ctx.ctx));
    projection_ctx.discardPendingTasks();
    try std.testing.expect(projection_app.pages.changes.changes_projection.pending == null);
}

test "action refresh closes source rejection after its already-started status member finishes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .{ .patch_file = "change.patch" } },
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearPendingReload(allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.changesNavigation().clearActionCursor(allocator);
    try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);

    // Leave exactly one task slot. Status takes it first; branch and source
    // spawn are then rejected. The action owner must retain the exact status
    // generation and close only when that already-started member terminates.
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(15);
    try std.testing.expectError(error.TaskLimitExceeded, changes_read.testing.startDiffLoadWithRepoRoot(
        app.changesRead(),
        &ctx.ctx,
        roots.a,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 9,
        },
    ));
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(changes_page.action_cursor.Terminal.rejected_spawn, basis.memberState(.source).?.terminal);
    try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);

    var status_task = ctx.takeTask(15).?;
    defer status_task.deinit();
    ctx.discardPendingTasks();
    const status_failure = try status_task.fail(error.ConcurrencyUnavailable);
    try finishOwnedChangesRead(&app, &ctx.ctx, status_failure);

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(app.pages.changes.status_load.pending == null);
}

test "read task allocation failure rejects source status branch and projection page state" {
    const backing = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var parent_environment = std.process.Environ.Map.init(backing);
    defer parent_environment.deinit();
    try parent_environment.put("HOME", "/test-home");

    var source_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    var source_app: ReadHarness = .{
        .allocator = source_failing.allocator(),
        .config = .{ .source = .unstaged },
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(backing, roots.a) } },
        .env_map = &parent_environment,
    };
    source_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer source_app.repo_session.repo_state.deinit(backing);
    defer source_app.pages.changes.deinit(backing);
    _ = source_app.pageCoordinator().activateChanges();
    try installTestActionCursor(&source_app, backing, .file, "source.txt", 9);
    try promoteTestActionCursor(&source_app, 9);
    var source_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    source_ctx.init(source_failing.allocator(), std.testing.io);
    defer source_ctx.deinit();
    try std.testing.expectError(error.OutOfMemory, changes_read.testing.startDiffLoadWithRepoRoot(
        source_app.changesRead(),
        &source_ctx.ctx,
        null,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 9,
        },
    ));
    try std.testing.expect(source_app.pages.changes.load.pending == null);
    try std.testing.expect(source_app.pages.changes.pending_reload == null);
    try std.testing.expect(source_app.pages.changes.canonical_publication == null);
    try std.testing.expect(!source_app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), source_ctx.pendingTaskCount());

    // Source request/root, canonical root/path, and status display root consume
    // four allocations. Fail the following non-empty environment clone after
    // both source and status page-owned pending state have been prepared.
    var status_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 4 });
    var status_app: ReadHarness = .{
        .allocator = status_failing.allocator(),
        .config = .{ .source = .unstaged },
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(backing, roots.a) } },
        .env_map = &parent_environment,
    };
    status_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer status_app.repo_session.repo_state.deinit(backing);
    defer status_app.pages.changes.deinit(backing);
    _ = status_app.pageCoordinator().activateChanges();
    try installTestActionCursor(&status_app, backing, .file, "status.txt", 10);
    try promoteTestActionCursor(&status_app, 10);
    var status_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    status_ctx.init(status_failing.allocator(), std.testing.io);
    defer status_ctx.deinit();
    try std.testing.expectError(error.OutOfMemory, changes_read.testing.startDiffLoadWithRepoRoot(
        status_app.changesRead(),
        &status_ctx.ctx,
        roots.a,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 10,
        },
    ));
    try std.testing.expect(status_app.pages.changes.load.pending == null);
    try std.testing.expect(status_app.pages.changes.pending_reload == null);
    try std.testing.expect(status_app.pages.changes.canonical_publication == null);
    try std.testing.expect(status_app.pages.changes.status_load.pending == null);
    try std.testing.expect(!status_app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), status_ctx.pendingTaskCount());

    var branch_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    var branch_app: ReadHarness = .{
        .allocator = branch_failing.allocator(),
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(backing, roots.a) } },
    };
    branch_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer branch_app.repo_session.repo_state.deinit(backing);
    _ = branch_app.pageCoordinator().activateChanges();
    var branch_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    branch_ctx.init(branch_failing.allocator(), std.testing.io);
    defer branch_ctx.deinit();
    _ = changes_read.testing.startBranchStatusLoad(branch_app.changesRead(), &branch_ctx.ctx, roots.a, null);
    try std.testing.expect(branch_app.pages.changes.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not allocate branch status load task", branch_app.pages.changes.status.text());

    var projection_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 4 });
    var projection_app: ReadHarness = .{
        .allocator = projection_failing.allocator(),
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(backing, roots.a) },
        },
    };
    projection_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer projection_app.repo_session.repo_state.deinit(backing);
    _ = projection_app.pageCoordinator().activateChanges();
    defer projection_app.changesReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.changes.git_status.deinit();
    var mixed = try git_status.StatusBundle.parseOwned(backing, "MM a\x00");
    try projection_app.pages.changes.git_status.replace(roots.a, &mixed);
    var projection_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    projection_ctx.init(projection_failing.allocator(), std.testing.io);
    defer projection_ctx.deinit();
    try std.testing.expectError(error.OutOfMemory, projection_app.changesRead().ensureProjection(&projection_ctx.ctx));
    try std.testing.expect(projection_app.pages.changes.changes_projection.pending == null);
}

test "stale branch status result is ignored" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .branch_status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.pages.changes.branch_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .branch = "stale",
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead = 1,
        .behind = 0,
    });

    app.changesRead().finishBranchStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.branch_status.repo_root == null);
    try std.testing.expect(std.meta.eql(git_branch_status.Head.unknown, app.pages.changes.branch_status.status.head));
    try std.testing.expectEqual(@as(?u64, 2), if (app.pages.changes.branch_status_load.pending) |pending| pending.generation else null);
}

test "Changes page header identical branch recovery redraws fresh terminal" {
    var app: ReadHarness = .{ .allocator = std.testing.allocator };
    defer app.pages.changes.branch_status.deinit();
    var current = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace("/repo", &current);
    const root_ptr = app.pages.changes.branch_status.repo_root.?.ptr;

    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .branch));
    const generation = app.pages.changes.branch_status_load.prepare(true);
    app.pages.changes.branch_status_load.begin(cycle_id, .{});
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    app.changesRead().finishBranchStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient branch failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.changes.branch_status.repo_root.?);
    try std.testing.expect(!app.pages.changes.branch_status_load.isFresh());
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.changes.branch_status_load.prepare(true);
    app.pages.changes.branch_status_load.begin(null, .{});
    app.redraw_plan = .{};
    const same = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead = 1,
        .behind = 0,
    });
    app.changesRead().finishBranchStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.changes.branch_status_load.isFresh());
    try std.testing.expectEqual(root_ptr, app.pages.changes.branch_status.repo_root.?.ptr);
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "generated projection syntax start failures preserve plain display and remain retryable" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: ReadHarness = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, root_path);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    app.pages.changes.load = app_test_support.loadState(app_test_support.loadedDiffOne());
    app.pages.changes.viewer.selected_target = .{ .status_only = 0 };
    _ = app.pages.changes.activation.activate(0, .pending, .pending, .pending);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? new.zig\x00");
    try app.pages.changes.git_status.replace(root_path, &status_bundle);
    app.pages.changes.changes_projection.installReady(.{
        .request = try app_changes_projection.testing.cloneRequestWithRootIdentity(
            allocator,
            app.pages.changes.activation.currentIdentity().?,
            11,
            root_path,
            "new.zig",
            .generated_added_file,
            .unstaged,
            0,
            0,
            app.repo_session.repo_state.root.?.identity,
        ),
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(
            allocator,
            "new.zig",
            "const value = 1;\n",
        ) },
    });

    // Failure while preparing the two owned request clones must not escape the
    // read coordinator's best-effort decoration path or leave a pending owner.
    app.terminal_size = .{ .width = 80, .height = 24 };
    var prepare_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    app.allocator = prepare_failing.allocator();
    var prepare_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    prepare_ctx.init(prepare_failing.allocator(), io);
    defer prepare_ctx.deinit();
    try app.changesRead().ensureProjection(&prepare_ctx.ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.changes.changes_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), prepare_ctx.pendingTaskCount());
    try expectGeneratedProjectionEligible(&app);

    // Four string allocations build the page/task request clones. Fail the
    // following task-object allocation and verify both clones are reclaimed.
    var task_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 4 });
    app.allocator = task_failing.allocator();
    var allocation_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    allocation_ctx.init(task_failing.allocator(), io);
    defer allocation_ctx.deinit();
    try app.changesRead().ensureProjection(&allocation_ctx.ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.changes.changes_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.pendingTaskCount());
    try expectGeneratedProjectionEligible(&app);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!ReadHarness.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskStartError) ReadHarness.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    spawn_ctx.init(allocator, io);
    defer spawn_ctx.deinit();
    for (0..16) |_| _ = try spawn_ctx.ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    try app.changesRead().ensureProjection(&spawn_ctx.ctx);
    try std.testing.expect(!app.pages.changes.changes_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.pendingTaskCount());
    spawn_ctx.discardPendingTasks();
    try expectGeneratedProjectionEligible(&app);

    var retry_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    retry_ctx.init(allocator, io);
    defer retry_ctx.deinit();
    try app.changesRead().ensureProjection(&retry_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 1), retry_ctx.pendingTaskCount());
    var queued = retry_ctx.takeTask(0).?;
    defer queued.deinit();
    try std.testing.expect(app.pages.changes.changes_projection.hasSyntaxPending());
    try expectGeneratedProjectionEligible(&app);
    queued.deinit();
}

test "combined projection target is requested for mixed modified unstaged files" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
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

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);

    const target = app.changesReloadView().projectionTarget() orelse return error.ExpectedCombinedProjectionTarget;
    try std.testing.expectEqual(app_changes_projection.Kind.combined_hunks, target.kind);
    try std.testing.expectEqual(app_changes_projection.SourceKind.unstaged, target.source_kind);
    try std.testing.expectEqualStrings("/repo", target.repo_root);
    try std.testing.expectEqualStrings("a", target.path_key);

    app.config.source = .{ .patch_file = "change.patch" };
    try std.testing.expect(app.changesReloadView().projectionTarget() == null);
}

test "Changes ordinary primary publication retains primary until cached result" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]bool{ false, true }) |status_first| {
        var app = try ordinaryPrimaryPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();

        app.changesNavigation().enterSearchMode();
        setDiffSearchInput(&app, "new");
        app.changesNavigation().submitSearch(std.testing.allocator);
        try std.testing.expect(app.pages.changes.search.match != null);
        const primary = switch (app.changesNavigationView().displayedChangesBody()) {
            .primary => |value| value,
            else => return error.ExpectedOrdinaryPrimary,
        };
        const primary_owner = primary.loaded;
        const primary_token = try installCanonicalPublicationLineageOwners(
            &app,
            allocator,
            roots.a,
        );
        const source_revision_before = app.pages.changes.source_session_revision;
        const status_revision_before = app.pages.changes.status_snapshot_revision;
        const horizontal_before = app.pages.changes.viewer.diff_horizontal_scroll;

        try finishCanonicalPublicationAction(
            &app,
            &ctx.ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);

        if (status_first) {
            try finishCanonicalPublicationStatus(
                &app,
                &ctx.ctx,
                allocator,
                roots.a,
                reads,
                "M  a\x00",
            );
        } else {
            try finishCanonicalPublicationEmpty(&app, &ctx.ctx, reads);
        }
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);

        if (status_first) {
            try finishCanonicalPublicationEmpty(&app, &ctx.ctx, reads);
        } else {
            try finishCanonicalPublicationStatus(
                &app,
                &ctx.ctx,
                allocator,
                roots.a,
                reads,
                "M  a\x00",
            );
        }
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);

        try app.changesRead().ensureProjection(&ctx.ctx);
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx);
        var request_owned = true;
        defer if (request_owned) request.deinit(allocator);
        try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, request.kind);
        try std.testing.expectEqualStrings("a", request.path_key);
        try std.testing.expect(request.expected_presentation == null);
        request_owned = false;
        try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
            .request = request,
            .result = .{ .ready = .{
                .cached_diff = try app_load.buildLoadedBundle(
                    allocator,
                    app_test_support.diff_cached_projection,
                ),
            } },
        });
        request = undefined;
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

        try std.testing.expect(app.changesNavigationView().displayedChangesBody() == .cached);
        try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);
        try std.testing.expectEqual(
            source_revision_before + 1,
            app.pages.changes.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before + 1,
            app.pages.changes.status_snapshot_revision,
        );
        try std.testing.expect(app.pages.changes.status_load.isFresh());
        try std.testing.expectEqualStrings(
            "a",
            app.changesNavigationView().selectedStagePathKey().?,
        );
        try std.testing.expectEqual(
            context.SelectedTarget{ .status_only = 0 },
            app.pages.changes.viewer.selected_target.?,
        );
        try std.testing.expectEqualStrings("new", app.pages.changes.search.query.slice());
        try std.testing.expect(app.pages.changes.search.match != null);
        try std.testing.expect(
            app.pages.changes.viewer.diff_scroll.row() <
                app.changesNavigationView().displayedDiffLineCount(),
        );
        try std.testing.expect(
            app.pages.changes.viewer.diff_horizontal_scroll <= horizontal_before,
        );
        try std.testing.expect(app.pages.changes.completed_selection == null);
        try std.testing.expect(!app.pages.changes.staged_hunks.containsExact(
            roots.a,
            "a",
            .{ .content = primary_token, .display_hunk_index = 1 },
        ));
        const final_token = app.changesNavigationView().currentContentToken() orelse
            return error.ExpectedFinalCachedContentToken;
        try std.testing.expect(!final_token.eql(primary_token));
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));

        switch (app.changesOperations().stageTarget()) {
            .already_staged => |path| try std.testing.expectEqualStrings("a", path),
            else => return error.ExpectedAlreadyStagedFile,
        }
        switch (app.changesOperations().toggleStageTarget()) {
            .operation => |operation| try std.testing.expectEqual(
                ToggleStageOperation.unstage,
                operation,
            ),
            else => return error.ExpectedFileUnstageOperation,
        }
        switch (app.changesOperations().unstageTarget()) {
            .ready => |target| {
                try std.testing.expectEqualStrings(roots.a, target.repo_root);
                try std.testing.expectEqualStrings("a", target.path);
            },
            else => return error.ExpectedFileUnstageCapability,
        }

        app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
        switch (app.changesOperations().selectedHunkToggleOperation()) {
            .operation => |operation| try std.testing.expectEqual(
                ToggleStageOperation.unstage,
                operation,
            ),
            else => return error.ExpectedHunkUnstageOperation,
        }
        switch (app.changesOperations().selectedHunkStageTarget(allocator)) {
            .already_staged_hunk => {},
            else => return error.ExpectedAlreadyStagedHunk,
        }
        switch (app.changesOperations().selectedHunkUnstageTarget(allocator)) {
            .ready => |target| {
                defer allocator.free(target.patch);
                try std.testing.expectEqualStrings(roots.a, target.repo_root);
                try std.testing.expectEqualStrings("a", target.path);
                try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
                try std.testing.expect(target.session_mark_mutation == .none);
            },
            else => return error.ExpectedHunkUnstageCapability,
        }
    }

    for ([_]bool{ false, true }) |source_changes| {
        try expectOrdinaryPrimaryNoTargetPublication(
            allocator,
            roots.a,
            source_changes,
        );
    }

    try expectOrdinaryPrimaryCandidateTargetMatrix();
}

test "Changes canonical publication exact acceptance retains navigation search and completed selection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationPrimaryTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.terminal_size.height = 12;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    app.changesNavigation().enterSearchMode();
    setDiffSearchInput(&app, "staged");
    app.changesNavigation().submitSearch(std.testing.allocator);
    const search_before = app.pages.changes.search.match orelse return error.ExpectedSearchMatch;
    const search_offset_before = app.pages.changes.search.match_offset;
    app.pages.changes.viewer.diff_horizontal_scroll = 2;
    const horizontal_before = app.pages.changes.viewer.diff_horizontal_scroll;
    const sidebar_horizontal_before = app.pages.changes.viewer.sidebar_horizontal_scroll;

    const displayed = app.changesNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = if (app.changesNavigationView().effectiveDisplayMode() == .unified)
            .unified_diff
        else
            .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 1, .line_index = 0 },
        .focus = .{ .hunk_index = 1, .line_index = 0 },
        .moved = true,
    };
    app.pages.changes.completed_selection = try content_selection.buildParsedFolded(
        allocator,
        app.changesNavigationView().currentContentToken() orelse return error.ExpectedContentToken,
        displayed,
        app.changesNavigationView().selectedFoldedHunks(),
        app.pages.changes.selection_layout_revision,
        selection,
    );
    const selected_tail = app.changesNavigationView().displayedDiffLineCount() -|
        app.changesNavigationView().diffVisibleRows();
    app.pages.changes.viewer.diff_scroll = .{ .logical = selected_tail };
    const selection_viewport_before = app.changesNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedSelectionViewportAnchor;
    try std.testing.expectEqual(selected_tail, selection_viewport_before.raw_presentation_scroll);
    switch (selection_viewport_before.semantic_source) {
        .parsed => |coordinate| app.pages.changes.viewer.diff_cursor = coordinate,
        .none, .generated_row => return error.ExpectedParsedSelectionViewportSource,
    }
    const cursor_before = app.pages.changes.viewer.diff_cursor;
    const scroll_before = app.pages.changes.viewer.diff_scroll.row();
    const token_before = app.pages.changes.completed_selection.?.token;
    const clipboard_before = try app.pages.changes.completed_selection.?.clipboardText(allocator);
    defer allocator.free(clipboard_before);
    const source_revision_before = app.pages.changes.source_session_revision;
    const status_revision_before = app.pages.changes.status_snapshot_revision;

    try finishCanonicalPublicationAction(&app, &ctx.ctx, allocator, .stage_file, roots.a);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationSource(
        &app,
        &ctx.ctx,
        allocator,
        reads,
        canonical_publication_combined_diff,
    );
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
    try app.changesRead().ensureProjection(&ctx.ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx);
    var candidate = try canonicalPublicationReuseCandidate(
        allocator,
        request.status_snapshot_revision,
    );
    const current = app.changesNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    try std.testing.expect(diff_presentation_identity.exactEqual(current, candidate.displayFile()));
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    });
    candidate = undefined;
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

    try std.testing.expectEqual(cursor_before, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(horizontal_before, app.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(sidebar_horizontal_before, app.pages.changes.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqualStrings("staged", app.pages.changes.search.query.slice());
    try std.testing.expect(app.pages.changes.search.match != null);
    try std.testing.expectEqual(search_before.coordinate, app.pages.changes.search.match.?.coordinate);
    try std.testing.expectEqual(search_offset_before, app.pages.changes.search.match_offset);
    const completed = app.pages.changes.completed_selection orelse
        return error.ExpectedRetainedCompletedSelection;
    const selection_viewport_after = app.changesNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedRetainedSelectionViewportAnchor;
    try std.testing.expect(selection_viewport_before.basis.eql(selection_viewport_after.basis));
    try std.testing.expectEqual(
        selection_viewport_before.raw_presentation_scroll,
        app.pages.changes.viewer.diff_scroll.row(),
    );
    const token_after = app.changesNavigationView().currentContentToken() orelse
        return error.ExpectedContentToken;
    try std.testing.expect(!token_after.eql(token_before));
    try std.testing.expect(completed.token.eql(token_after));
    const clipboard_after = try completed.clipboardText(allocator);
    defer allocator.free(clipboard_after);
    try std.testing.expectEqualStrings(clipboard_before, clipboard_after);

    try std.testing.expectEqual(
        source_revision_before + 1,
        app.pages.changes.source_session_revision,
    );
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.changes.status_snapshot_revision,
    );
    const published_request = app.pages.changes.changes_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(published_request.matchesBorrowed(
        app.pages.changes.repository_read_authority.epoch,
        roots.a,
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    ));
    try std.testing.expect(published_request.matchesRootIdentity(app.repoSessionView().activeIdentity()));
    const expected_presentation = published_request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .primary_loaded);
    try std.testing.expect(app.changesNavigationView().activeCombinedProjection() == null);
    const authority = app.changesNavigationView().activeHunkAuthority() orelse
        return error.ExpectedFreshHunkAuthority;
    try std.testing.expect(authority.authority == .combined);
    try std.testing.expectEqual(
        app.pages.changes.status_snapshot_revision,
        authority.authority.statusSnapshotRevision(),
    );
    try std.testing.expectEqual(@as(usize, 2), authority.hunkStageStates().len);
    try std.testing.expectEqual(@as(usize, 2), authority.hunkActionOrigins().len);
    try std.testing.expect(authority.hunkActionOrigins()[0] == .cached);
    try std.testing.expect(authority.hunkActionOrigins()[1] == .unstaged);
    const cached_source = authority.actionSourceFile(authority.hunkActionOrigins()[0]) orelse
        return error.ExpectedFreshCachedActionSource;
    const unstaged_source = authority.actionSourceFile(authority.hunkActionOrigins()[1]) orelse
        return error.ExpectedFreshUnstagedActionSource;
    try std.testing.expectEqualStrings("a", diff_file.canonicalPathKey(cached_source).?);
    try std.testing.expectEqualStrings("a", diff_file.canonicalPathKey(unstaged_source).?);
    // The focused viewport proof above intentionally uses a four-row diff
    // body. Restore the fixture's normal geometry before the existing action
    // capability assertions, which require both hunks to be visible.
    app.terminal_size.height = 40;
    try expectFreshCanonicalActionCapabilities(&app, allocator, roots.a);
}

test "Changes canonical publication exact reuse rebinds every retained lineage owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    const PresentationOwner = enum { self_owned, primary_backed };
    const ReuseKind = enum { combined, staged_only };
    for ([_]PresentationOwner{ .self_owned, .primary_backed }) |owner| {
        for ([_]ReuseKind{ .combined, .staged_only }) |kind| {
            var app = switch (owner) {
                .self_owned => try canonicalPublicationTestApp(allocator, roots.a),
                .primary_backed => try canonicalPublicationPrimaryTestApp(allocator, roots.a),
            };
            defer app.pages.changes.deinit(allocator);
            defer app.repo_session.repo_state.deinit(allocator);
            var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
            ctx.init(allocator, std.testing.io);
            defer ctx.deinit();

            const token_before = try installCanonicalPublicationLineageOwners(
                &app,
                allocator,
                roots.a,
            );
            const clipboard_before = try app.pages.changes.completed_selection.?.clipboardText(
                allocator,
            );
            defer allocator.free(clipboard_before);
            const source_revision_before = app.pages.changes.source_session_revision;

            try finishCanonicalPublicationAction(
                &app,
                &ctx.ctx,
                allocator,
                .stage_file,
                roots.a,
            );
            const reads = try takeCanonicalPublicationReads(&ctx, allocator);
            try finishCanonicalPublicationSource(
                &app,
                &ctx.ctx,
                allocator,
                reads,
                canonical_publication_combined_diff,
            );
            try finishCanonicalPublicationStatus(
                &app,
                &ctx.ctx,
                allocator,
                roots.a,
                reads,
                switch (kind) {
                    .combined => "MM a\x00",
                    .staged_only => "M  a\x00",
                },
            );
            try app.changesRead().ensureProjection(&ctx.ctx);
            var request = try takeCanonicalPublicationProjectionRequest(&ctx);
            try std.testing.expectEqual(
                switch (kind) {
                    .combined => app_changes_projection.Kind.combined_hunks,
                    .staged_only => app_changes_projection.Kind.cached_diff,
                },
                request.kind,
            );
            const expected = request.expected_presentation orelse
                return error.ExpectedPriorCanonicalPresentation;
            try std.testing.expectEqual(
                switch (owner) {
                    .self_owned => app_changes_projection.ExpectedPresentationOwner.combined_projection,
                    .primary_backed => app_changes_projection.ExpectedPresentationOwner.primary_loaded,
                },
                expected.owner,
            );
            switch (kind) {
                .combined => {
                    var candidate = try canonicalPublicationReuseCandidate(
                        allocator,
                        request.status_snapshot_revision,
                    );
                    const current = app.changesNavigationView().displayedDiffFile() orelse
                        return error.ExpectedDisplayedDiff;
                    try std.testing.expect(diff_presentation_identity.exactEqual(
                        current,
                        candidate.displayFile(),
                    ));
                    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
                        .request = request,
                        .result = .{ .reuse_candidate = candidate },
                    });
                    candidate = undefined;
                },
                .staged_only => {
                    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
                        allocator,
                        request.status_snapshot_revision,
                    );
                    const current = app.changesNavigationView().displayedDiffFile() orelse
                        return error.ExpectedDisplayedDiff;
                    try std.testing.expect(diff_presentation_identity.exactEqual(
                        current,
                        candidate.displayFile(),
                    ));
                    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
                        .request = request,
                        .result = .{ .staged_only_reuse_candidate = candidate },
                    });
                    candidate = undefined;
                },
            }
            request = undefined;
            try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

            try std.testing.expectEqual(
                source_revision_before + 1,
                app.pages.changes.source_session_revision,
            );
            const token_after = app.changesNavigationView().currentContentToken() orelse
                return error.ExpectedContentToken;
            try std.testing.expect(!token_after.eql(token_before));
            const completed = app.pages.changes.completed_selection orelse
                return error.ExpectedRetainedCompletedSelection;
            try std.testing.expect(completed.token.eql(token_after));
            const clipboard_after = try completed.clipboardText(allocator);
            defer allocator.free(clipboard_after);
            try std.testing.expectEqualStrings(clipboard_before, clipboard_after);
            try std.testing.expect(app.pages.changes.staged_hunks.containsExact(
                roots.a,
                "a",
                .{ .content = token_after, .display_hunk_index = 1 },
            ));
            try std.testing.expect(!app.pages.changes.staged_hunks.containsExact(
                roots.a,
                "a",
                .{ .content = token_before, .display_hunk_index = 1 },
            ));
        }
    }
}

test "Changes canonical publication startup and status failure retain last good owners" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        const prior = app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        try ctx.fillTaskSlots(16);
        try finishCanonicalPublicationAction(&app, &ctx.ctx, allocator, .stage_file, roots.a);
        ctx.discardPendingTasks();
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(app.pages.changes.pending_reload == null);
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
    }

    for ([_]bool{ false, true }) |status_first| {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        const prior = app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        try finishCanonicalPublicationAction(&app, &ctx.ctx, allocator, .stage_file, roots.a);
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);

        if (!status_first) {
            try finishCanonicalPublicationSource(
                &app,
                &ctx.ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            );
        }
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = reads.status_identity,
            .read_epoch = reads.status_read_epoch,
            .generation = reads.status_generation,
            .background_cycle_id = reads.status_cycle_id,
            .repo_root = try allocator.dupe(u8, roots.a),
            .result = .{ .failed_static = "status failed" },
        });
        if (status_first) {
            try finishCanonicalPublicationSource(
                &app,
                &ctx.ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            );
        }
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(app.pages.changes.pending_reload == null);
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
    }

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        const prior = app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        const source_revision_before = app.pages.changes.source_session_revision;
        const status_revision_before = app.pages.changes.status_snapshot_revision;

        const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
        try finishCanonicalPublicationSource(
            &app,
            &ctx.ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationStatusFailure(&app, &ctx.ctx, allocator, roots.a, reads);

        try std.testing.expect(app.pages.changes.deferred_source_apply == null);
        const cycle = app.pages.changes.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(cycle_id, cycle.id);
        try std.testing.expect(!cycle.pending.source);
        try std.testing.expect(!cycle.pending.status);
        try std.testing.expect(!cycle.pending.deferred_source_apply);
        try std.testing.expect(cycle.pending.branch);
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

        try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.changes.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before,
            app.pages.changes.status_snapshot_revision,
        );
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
    }

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.changes.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
        const prior = app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        const prior_content_token = prior.presentation.content_token;
        const source_revision_before = app.pages.changes.source_session_revision;
        const status_revision_before = app.pages.changes.status_snapshot_revision;
        const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const failed_cycle_id = reads.source_cycle_id orelse
            return error.ExpectedBackgroundCycle;
        try finishCanonicalPublicationSource(
            &app,
            &ctx.ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, failed_cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
        try expectRetainedCanonicalPublication(&app, prior_hunks);

        try ctx.fillTaskSlots(16);
        try std.testing.expectError(error.TaskLimitExceeded, app.changesRead().ensureProjection(&ctx.ctx));
        ctx.discardPendingTasks();
        try std.testing.expect(app.pages.changes.deferred_source_apply == null);
        const failed_cycle = app.pages.changes.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(failed_cycle_id, failed_cycle.id);
        try std.testing.expect(!failed_cycle.pending.source);
        try std.testing.expect(!failed_cycle.pending.status);
        try std.testing.expect(!failed_cycle.pending.deferred_source_apply);
        try std.testing.expect(failed_cycle.pending.branch);
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.changes.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before,
            app.pages.changes.status_snapshot_revision,
        );
        try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
        try std.testing.expect(app.pages.changes.pending_reload == null);
        try std.testing.expect(app.pages.changes.changes_projection.pending == null);
        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));

        const retry_reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const retry_cycle_id = retry_reads.source_cycle_id orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expect(retry_cycle_id > failed_cycle_id);
        try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, retry_reads, "MM a\x00");
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationSource(
            &app,
            &ctx.ctx,
            allocator,
            retry_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, retry_cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try app.changesRead().ensureProjection(&ctx.ctx);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx);
        const final_bundle = try canonicalPublicationFinalBundle(allocator, request);
        try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
            .request = request,
            .result = .{ .ready = .{ .combined_hunks = final_bundle } },
        });
        request = undefined;
        try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, retry_reads);

        try std.testing.expect(app.pages.changes.deferred_source_apply == null);
        try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
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
        try std.testing.expect(app.pages.changes.pending_reload == null);
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
    }
}

test "Changes canonical publication projection failure publishes failure body atomically" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.terminal_size.height = 12;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const source_revision_before = app.pages.changes.source_session_revision;
    const status_revision_before = app.pages.changes.status_snapshot_revision;
    const prior = app.changesNavigationView().activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    _ = try installCanonicalPublicationLineageOwners(&app, allocator, roots.a);
    const selected_tail = app.changesNavigationView().displayedDiffLineCount() -|
        app.changesNavigationView().diffVisibleRows();
    app.pages.changes.viewer.diff_scroll = .{ .logical = selected_tail };
    const selection_viewport_before = app.changesNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedSelectionViewportAnchor;
    try std.testing.expectEqual(selected_tail, selection_viewport_before.raw_presentation_scroll);
    switch (selection_viewport_before.semantic_source) {
        .parsed => |coordinate| app.pages.changes.viewer.diff_cursor = coordinate,
        .none, .generated_row => return error.ExpectedParsedSelectionViewportSource,
    }

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try finishCanonicalPublicationSource(
        &app,
        &ctx.ctx,
        allocator,
        reads,
        app_test_support.diff_unstaged_projection,
    );
    try expectCanonicalPublicationCycleTransfer(&app, cycle_id);
    try expectRetainedCanonicalPublication(&app, prior_hunks);

    try app.changesRead().ensureProjection(&ctx.ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx);
    const expected_source_revision = request.source_session_revision;
    const expected_status_revision = request.status_snapshot_revision;
    try std.testing.expectEqual(source_revision_before + 1, expected_source_revision);
    try std.testing.expectEqual(status_revision_before, expected_status_revision);
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = request,
        .result = .{ .failed_static = "projection failed" },
    });
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

    // The publication route's failure arm commits
    // atomically — the gate is consumed, the accepted source and status are
    // published exactly once, and the preallocated failure body becomes the
    // displayed projection instead of leaving a stale retained body plus a
    // live transaction.
    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
    try std.testing.expectEqual(expected_source_revision, app.pages.changes.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.changes.status_snapshot_revision);
    switch (app.pages.changes.changes_projection.displayed) {
        .failed => {},
        else => return error.ExpectedFailedProjectionDisplay,
    }
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(app.pages.changes.completed_selection == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        app.changesNavigationView().restoredViewport(selection_viewport_before).row(),
    );
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
}

test "Changes canonical publication changed status waits for unchanged source and stale generations drain" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const status_revision_before = app.pages.changes.status_snapshot_revision;
    const source_revision_before = app.pages.changes.source_session_revision;
    const prior = app.changesNavigationView().activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const prior_content_token = app.changesNavigationView().currentContentToken() orelse
        return error.ExpectedContentToken;
    try finishCanonicalPublicationAction(&app, &ctx.ctx, allocator, .stage_file, roots.a);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "M  a\x00");

    try std.testing.expectEqual(status_revision_before, app.pages.changes.status_snapshot_revision);
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("unchanged") },
    });
    try std.testing.expectEqual(source_revision_before, app.pages.changes.source_session_revision);
    try expectRetainedCanonicalPublication(&app, prior_hunks);

    try app.changesRead().ensureProjection(&ctx.ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx);
    var request_owned = true;
    defer if (request_owned) request.deinit(allocator);
    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, request.kind);
    const stale_request = try app_changes_projection.cloneRequestWithOptions(
        allocator,
        request.identity,
        request.id,
        request.repo_root,
        request.path_key,
        request.kind,
        request.source_kind,
        request.source_session_revision,
        request.status_snapshot_revision,
        .{
            .read_epoch = request.read_epoch.next(),
            .root_identity = request.root_identity,
            .expected_presentation = request.expected_presentation,
        },
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = stale_request,
        .result = .{ .ready = .{
            .cached_diff = try app_load.buildLoadedBundle(
                allocator,
                app_test_support.diff_cached_projection,
            ),
        } },
    });
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try std.testing.expect(app.pages.changes.changes_projection.hasPending());

    request_owned = false;
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = request,
        .result = .{ .ready = .{
            .cached_diff = try app_load.buildLoadedBundle(
                allocator,
                app_test_support.diff_cached_projection,
            ),
        } },
    });
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

    try std.testing.expectEqual(source_revision_before, app.pages.changes.source_session_revision);
    try std.testing.expectEqual(status_revision_before + 1, app.pages.changes.status_snapshot_revision);
    try std.testing.expect(app.changesNavigationView().displayedChangesBody() == .cached);
    try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);
    const published_request = app.pages.changes.changes_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(published_request.matchesBorrowed(
        app.pages.changes.repository_read_authority.epoch,
        roots.a,
        "a",
        .cached_diff,
        .unstaged,
        source_revision_before,
        status_revision_before + 1,
    ));
    try std.testing.expect(!app.changesNavigationView().currentContentToken().?.eql(
        prior_content_token,
    ));
    try std.testing.expect(app.pages.changes.completed_selection == null);
    switch (app.changesOperations().stageTarget()) {
        .already_staged => |path| try std.testing.expectEqualStrings("a", path),
        else => return error.ExpectedAlreadyStagedFile,
    }
    switch (app.changesOperations().unstageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFileUnstageCapability,
    }
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(
            ToggleStageOperation.unstage,
            operation,
        ),
        else => return error.ExpectedHunkUnstageOperation,
    }
    switch (app.changesOperations().selectedHunkStageTarget(allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedHunk,
    }
    switch (app.changesOperations().selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedHunkUnstageCapability,
    }
    try std.testing.expect(!app.pages.changes.changes_projection.hasPending());
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));

    {
        var mixed_app = try canonicalPublicationTestApp(allocator, roots.a);
        defer mixed_app.pages.changes.deinit(allocator);
        defer mixed_app.repo_session.repo_state.deinit(allocator);
        var mixed_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        mixed_ctx.init(allocator, std.testing.io);
        defer mixed_ctx.deinit();
        const mixed_status_revision = mixed_app.pages.changes.status_snapshot_revision;
        const mixed_source_revision = mixed_app.pages.changes.source_session_revision;
        const mixed_prior = mixed_app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const mixed_hunks = mixed_prior.displayFile().hunks.ptr;
        const mixed_content_token = mixed_prior.presentation.content_token;

        try finishCanonicalPublicationAction(
            &mixed_app,
            &mixed_ctx.ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        const mixed_reads = try takeCanonicalPublicationReads(&mixed_ctx, allocator);
        try finishCanonicalPublicationStatus(
            &mixed_app,
            &mixed_ctx.ctx,
            allocator,
            roots.a,
            mixed_reads,
            "MM a\x00 M b\x00",
        );
        try mixed_app.changesRead().finishDiffLoad(mixed_ctx.ctx.allocator(), .{
            .identity = mixed_reads.source_identity,
            .read_epoch = mixed_reads.source_read_epoch,
            .generation = mixed_reads.source_generation,
            .background_cycle_id = mixed_reads.source_cycle_id,
            .result = .{
                .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
            },
        });
        try expectRetainedCanonicalPublication(&mixed_app, mixed_hunks);

        try mixed_app.changesRead().ensureProjection(&mixed_ctx.ctx);
        var mixed_request = try takeCanonicalPublicationProjectionRequest(
            &mixed_ctx,
        );
        var mixed_request_owned = true;
        defer if (mixed_request_owned) mixed_request.deinit(allocator);
        try std.testing.expectEqual(
            app_changes_projection.Kind.combined_hunks,
            mixed_request.kind,
        );
        const mixed_final = try canonicalPublicationFinalBundle(
            allocator,
            mixed_request,
        );
        mixed_request_owned = false;
        try mixed_app.changesRead().finishProjectionLoad(mixed_ctx.ctx.allocator(), .{
            .request = mixed_request,
            .result = .{ .ready = .{ .combined_hunks = mixed_final } },
        });
        mixed_request = undefined;
        try finishCanonicalPublicationBranch(
            &mixed_app,
            &mixed_ctx.ctx,
            allocator,
            roots.a,
            mixed_reads,
        );

        try expectFreshCanonicalPublication(
            &mixed_app,
            allocator,
            roots.a,
            mixed_hunks,
            mixed_content_token,
            mixed_source_revision,
            mixed_status_revision + 1,
            true,
        );
    }

    {
        var superseded_app = try canonicalPublicationTestApp(allocator, roots.a);
        defer superseded_app.pages.changes.deinit(allocator);
        defer superseded_app.repo_session.repo_state.deinit(allocator);
        var superseded_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        superseded_ctx.init(allocator, std.testing.io);
        defer superseded_ctx.deinit();
        const superseded_status_revision = superseded_app.pages.changes.status_snapshot_revision;
        const superseded_source_revision = superseded_app.pages.changes.source_session_revision;
        const superseded_prior = superseded_app.changesNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const superseded_hunks = superseded_prior.displayFile().hunks.ptr;
        const superseded_content_token = superseded_prior.presentation.content_token;

        const old_reads = try startCanonicalPublicationWatch(
            &superseded_app,
            &superseded_ctx,
            allocator,
        );
        const old_cycle_id = old_reads.source_cycle_id orelse
            return error.ExpectedBackgroundCycle;
        try finishCanonicalPublicationSource(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            old_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&superseded_app, old_cycle_id);
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);

        try changes_read.testing.startDiffLoadWithRepoRoot(superseded_app.changesRead(), &superseded_ctx.ctx, roots.a, .{
            .clear_visible_state = false,
            .kind = .watch,
        });
        const new_reads = try takeCanonicalPublicationReads(&superseded_ctx, allocator);
        try std.testing.expect(new_reads.source_cycle_id == null);
        try std.testing.expect(new_reads.status_cycle_id == null);
        try std.testing.expect(new_reads.branch_cycle_id == null);
        try std.testing.expect(superseded_app.pages.changes.deferred_source_apply == null);
        const draining_cycle = superseded_app.pages.changes.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(old_cycle_id, draining_cycle.id);
        try std.testing.expect(!draining_cycle.pending.source);
        try std.testing.expect(!draining_cycle.pending.deferred_source_apply);
        try std.testing.expect(draining_cycle.pending.status);
        try std.testing.expect(draining_cycle.pending.branch);

        try finishCanonicalPublicationStatus(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            roots.a,
            old_reads,
            "M  a\x00",
        );
        try finishCanonicalPublicationBranch(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            roots.a,
            old_reads,
        );
        try std.testing.expect(superseded_app.pages.changes.auto_reload.background_cycle == null);
        try std.testing.expectEqual(
            superseded_source_revision,
            superseded_app.pages.changes.source_session_revision,
        );
        try std.testing.expectEqual(
            superseded_status_revision,
            superseded_app.pages.changes.status_snapshot_revision,
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);

        try finishCanonicalPublicationSource(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            new_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);
        try finishCanonicalPublicationStatus(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            roots.a,
            new_reads,
            "MM a\x00",
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);
        try superseded_app.changesRead().ensureProjection(&superseded_ctx.ctx);
        var superseded_request = try takeCanonicalPublicationProjectionRequest(
            &superseded_ctx,
        );
        const superseded_bundle = try canonicalPublicationFinalBundle(
            allocator,
            superseded_request,
        );
        try superseded_app.changesRead().finishProjectionLoad(superseded_ctx.ctx.allocator(), .{
            .request = superseded_request,
            .result = .{ .ready = .{ .combined_hunks = superseded_bundle } },
        });
        superseded_request = undefined;
        try finishCanonicalPublicationBranch(
            &superseded_app,
            &superseded_ctx.ctx,
            allocator,
            roots.a,
            new_reads,
        );

        try std.testing.expectEqual(
            superseded_source_revision + 1,
            superseded_app.pages.changes.source_session_revision,
        );
        try std.testing.expectEqual(
            superseded_status_revision,
            superseded_app.pages.changes.status_snapshot_revision,
        );
        try expectFreshCanonicalPublication(
            &superseded_app,
            allocator,
            roots.a,
            superseded_hunks,
            superseded_content_token,
            superseded_source_revision + 1,
            superseded_status_revision,
            true,
        );
        try std.testing.expect(!superseded_app.pages.changes.changes_projection.hasPending());
        try std.testing.expect(!superseded_app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(superseded_app.changesRead()));
    }
}

test "background status refresh retains combined projection while cursor moves" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 11,
            .status_snapshot_revision = 13,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 } },
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
    acceptTestSource(&app);

    const projection_before = app.changesNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.displayFile().hunks.ptr;
    const cursor_before = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_before > 0);

    _ = app.pages.changes.status_load.prepare(true);
    syncTestActivation(&app);
    app.pages.changes.load.generation +%= 1;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().ensureProjection(&ctx.ctx);

    const retained = app.changesNavigationView().activeCombinedProjection() orelse return error.ExpectedRetainedProjection;
    try std.testing.expectEqual(hunks_before, retained.displayFile().hunks.ptr);
    app.changesNavigation().moveDiffCursorRows(.down);
    const cursor_after = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_after > cursor_before);
    try std.testing.expect(cursor_after != 0);
    switch (app.changesOperations().selectedHunkToggleOperation()) {
        .stale_status => {},
        else => return error.ExpectedStaleProjectedHunkAuthority,
    }
}

test "unchanged full cycle preserves projection semantic identity" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 17,
            .status_snapshot_revision = 19,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = .{ .logical = 2 } },
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

    const projection_before = app.changesNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.displayFile().hunks.ptr;
    const cursor_before = app.pages.changes.viewer.diff_cursor;
    const scroll_before = app.pages.changes.viewer.diff_scroll.row();

    const status_generation = app.pages.changes.status_load.prepare(true);
    app.pages.changes.status_load.begin(1, .{});
    app.pages.changes.load.generation +%= 1;
    try std.testing.expect(app.pages.changes.status_load.finishTerminal(.{
        .generation = status_generation,
        .read_epoch = .{},
        .background_cycle_id = 1,
    }));
    app.pages.changes.status_load.markSuccess();

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().ensureProjection(&ctx.ctx);

    const projection_after = app.changesNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    try std.testing.expectEqual(hunks_before, projection_after.displayFile().hunks.ptr);
    try std.testing.expect(!app.pages.changes.changes_projection.hasPending());
    try std.testing.expectEqual(@as(u64, 17), app.pages.changes.source_session_revision);
    try std.testing.expectEqual(@as(u64, 19), app.pages.changes.status_snapshot_revision);
    try std.testing.expectEqual(cursor_before, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.changes.viewer.diff_scroll.row());
}

test "final projection prefers explicit interim navigation override" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 23,
            .status_snapshot_revision = 29,
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
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);

    const state_request = try app_changes_projection.testing.cloneRequest(
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
    app.pages.changes.changes_projection.pending = state_request;
    app.pages.changes.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.changes.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = .{ .logical = 4 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .override = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = .{ .logical = 0 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 4,
    };

    const result_request = try app_changes_projection.testing.cloneRequest(
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
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) } },
    });

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 0 }, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.changesNavigationView().selectedDiffCursorOffset());
}

test "empty watch source carries combined navigation into cached projection" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 }, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } },
            .source_session_revision = 37,
            .status_snapshot_revision = 41,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = .{ .logical = 3 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
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
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_changes_projection.testing.cloneRequest(
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
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    const original_offset = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(original_offset > 0);

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore != null);
    try std.testing.expect(app.changesNavigationView().activeLoadedDiffConst() != null);
    try std.testing.expectEqual(@as(usize, 0), app.changesNavigationView().activeLoadedDiffConst().?.document.files.len);

    const staged_only = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = staged_only },
    });
    const target = app.changesReloadView().projectionTarget() orelse return error.ExpectedCachedProjectionTarget;
    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, target.kind);

    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    const result_request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);
    const final_offset = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(final_offset > 0);
    try std.testing.expect(final_offset <= original_offset);
}

test "empty watch source carries generated navigation into generated projection" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .source_session_revision = 43,
            .status_snapshot_revision = 47,
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
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.pages.changes.git_status.replace("/repo", &untracked);
    try app.changesReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.changes.git_status.document);
    app.pages.changes.viewer.diff_cursor = .{ .metadata = 2 };
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } };
    app.pages.changes.pending_reload = .{ .generation = 2, .kind = .watch };

    const displayed_request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = displayed_request,
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\n") },
    } };
    const original_offset = app.changesNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expectEqual(@as(usize, 2), original_offset);

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore != null);

    const same_untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same_untracked },
    });
    const target = app.changesReloadView().projectionTarget() orelse return error.ExpectedGeneratedProjectionTarget;
    try std.testing.expectEqual(app_changes_projection.Kind.generated_added_file, target.kind);

    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    const result_request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\nfive\n") } },
    });

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expect(app.changesNavigationView().activeGeneratedFileProjection() != null);
    try std.testing.expectEqual(@as(?usize, 2), app.changesNavigationView().selectedDiffCursorOffset());
}

test "fresh empty status consumes pending display restore at raw terminal" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 }, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } },
            .source_session_revision = 53,
            .status_snapshot_revision = 59,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_changes_projection.testing.cloneRequest(
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
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expectEqual(@as(u64, 1), cycle_id);
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .status));

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{ .identity = page.RequestIdentity.changes(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore != null);

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expect(app.changesNavigationView().activeLoadedDiffConst() == null);
    try std.testing.expect(app.pages.changes.load.state == .empty);
}

test "selected path change supersedes pending display restore" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .source_session_revision = 61,
            .status_snapshot_revision = 67,
        } },
        .allocator = std.testing.allocator,
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
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00M  b\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try app.changesReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.changes.git_status.document);
    app.pages.changes.viewer.selected_target = .{ .status_only = 1 };
    app.pages.changes.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.changes.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .status_only,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = .{ .logical = 0 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };
    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        2,
        "/repo",
        "b",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().ensureProjection(&ctx.ctx);

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expect(app.pages.changes.changes_projection.pending != null);
    try std.testing.expectEqualStrings("b", app.pages.changes.changes_projection.pending.?.path_key);
}

test "file search selection remains authoritative through successor projection acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    const activation_id = app.pageCoordinator().activateChanges();

    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00M  b\x00");
    try app.pages.changes.git_status.replace(roots.a, &status);
    try app.changesReload().createStatusOnlyLoadedSession(allocator, app.pages.changes.git_status.document);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    app.pages.changes.pending_display_navigation_restore = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.changes.source_session_revision,
        .original = .{
            .path_key = try allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "a") },
            .selected_target_tag = .status_only,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = .{ .logical = 0 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = app.pages.changes.display_navigation_input_revision,
    };
    app.pages.changes.changes_projection_next_id = 1;
    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        allocator,
        page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        1,
        roots.a,
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try applyChangesStateOnly(&app, allocator, .enter_file_search);
    try applyChangesStateOnly(&app, allocator, .file_search_next);
    try applyChangesStateOnly(&app, allocator, .submit_file_search);
    try runReadCoordinationTail(&app, &ctx.ctx);

    try std.testing.expectEqualStrings("b", app.changesNavigationView().selectedStagePathKey().?);
    const pending = app.pages.changes.changes_projection.pending orelse return error.ExpectedProjectionForLaterSelection;
    try std.testing.expectEqual(@as(u64, 2), pending.id);
    try std.testing.expectEqualStrings("b", pending.path_key);

    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    ctx.discardPendingTasks();

    const result_request = try app_changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        pending.identity,
        pending.id,
        pending.repo_root,
        pending.path_key,
        pending.kind,
        pending.source_kind,
        pending.source_session_revision,
        pending.status_snapshot_revision,
        pending.root_identity.?,
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff) } },
    });

    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);
    try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);
    try std.testing.expectEqualStrings("b", app.changesNavigationView().selectedStagePathKey().?);
}

test "superseded projection completion cannot replace display" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .source_session_revision = 71,
            .status_snapshot_revision = 73,
        } },
        .allocator = std.testing.allocator,
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
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try app.changesReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.changes.git_status.document);
    const stale_status_revision = app.pages.changes.status_snapshot_revision - 1;
    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        stale_status_revision,
    );
    const result_request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        stale_status_revision,
    );
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(!app.pages.changes.changes_projection.hasDisplayed());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "old generated syntax completion drains pending and suppresses redraw" {
    const allocator = std.testing.allocator;
    const root_identity: repo_root_capability.Identity = .{ .device = 29, .inode = 31 };
    var app: ReadHarness = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
    };
    defer app.pages.changes.deinit(allocator);
    _ = app.pages.changes.activation.activate(0, .pending, .pending, .pending);
    app.pages.changes.repository_read_authority.epoch = .{ .value = 41 };
    app.pages.changes.changes_projection.installReady(.{
        .request = try app_changes_projection.cloneRequestWithOptions(
            allocator,
            app.pages.changes.activation.currentIdentity().?,
            11,
            "/repo",
            "new.zig",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{
                .read_epoch = app.pages.changes.repository_read_authority.epoch,
                .root_identity = root_identity,
            },
        ),
        .value = .{ .generated_added_file = try app_changes_projection.generatedFileFromContent(
            allocator,
            "new.zig",
            "const retained = true;\n",
        ) },
    });
    const bundle = &app.pages.changes.changes_projection.displayed.ready.value.generated_added_file;
    bundle.decoration = .eligible;
    app.pages.changes.changes_projection.syntax_pending = try app_changes_projection.generatedSyntaxRequestForProjection(
        allocator,
        17,
        app.pages.changes.activation.currentIdentity().?,
        app.pages.changes.changes_projection.displayed.ready.request,
        bundle.fingerprint(),
    );
    const old_epoch = app.pages.changes.repository_read_authority.epoch;
    app.pages.changes.repository_read_authority.epoch = old_epoch.next();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    app.changesRead().finishGeneratedProjectionSyntax(ctx.ctx.allocator(), .{
        .request = try app_changes_projection.cloneGeneratedSyntaxRequest(
            allocator,
            app.pages.changes.changes_projection.syntax_pending.?,
        ),
        .snapshot_fingerprint = bundle.fingerprint(),
        .result = .{ .terminal_plain = .provider_unavailable },
    });

    try std.testing.expect(app.pages.changes.changes_projection.syntax_pending == null);
    try std.testing.expect(bundle.decoration == .eligible);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "cached preview keeps search input while projection is pending" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
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
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.pending = request;

    app.changesNavigation().enterSearchMode();
    try std.testing.expect(app.pages.changes.search.mode);
    setDiffSearchInput(&app, "staged");
    app.changesNavigation().submitSearch(std.testing.allocator);
    try std.testing.expect(!app.pages.changes.search.mode);
    try std.testing.expect(app.pages.changes.search.match == null);
    try std.testing.expectEqualStrings("staged", app.pages.changes.search.query.slice());

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const ready_request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = ready_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.changes.search.match != null);
    try std.testing.expectEqual(@as(?usize, 2), app.pages.changes.search.match_offset);
}

test "finishDiffLoad applies active changed file filter" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 1 },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.reviewed_store.deinit(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_added_deleted);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 1), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(file_tree.Status.added, loaded.tree.nodes[1].status.?);
}

test "load runtime pending tracks task kind and generation" {
    var load: app_load_state.LoadRuntimeState = .{};

    const discovery_generation = load.beginRepoDiscovery();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(discovery_generation));
    try std.testing.expect(!load.finishPending(.{ .diff_load = discovery_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.finishPending(.{ .repo_discovery = discovery_generation }));
    try std.testing.expect(!load.hasPending());

    const diff_generation = load.beginDiffLoad();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(diff_generation));
    try std.testing.expect(load.clearPendingIfCurrent(.{ .diff_load = diff_generation }));
    try std.testing.expect(!load.hasPending());
}

test "load runtime keeps newer pending when stale task finishes" {
    var load: app_load_state.LoadRuntimeState = .{};

    const stale_generation = load.beginDiffLoad();
    const current_generation = load.beginDiffLoad();

    try std.testing.expect(!load.finishPending(.{ .diff_load = stale_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(current_generation));
    try std.testing.expect(load.finishPending(.{ .diff_load = current_generation }));
    try std.testing.expect(!load.hasPending());
}

test "finishDiffLoad takes current loaded bundle ownership" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.load.state == .loaded);
    try std.testing.expect(app.pages.changes.load.state.loaded.loaded.document.files.len > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.load.state.loaded.loaded.document.files.len);
}

test "finishDiffLoad initially selects first visible file node" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
}

test "finishDiffLoad initially selects first visible file after status projection" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.changesNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.changes.viewer.selected_target.?);
}

test "finishDiffLoad keeps initial visible selection intent for later status projection" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 1 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.pending_initial_first_visible_selection);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    try std.testing.expect(!app.pages.changes.pending_initial_first_visible_selection);

    const loaded = app.changesNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.changes.viewer.selected_target.?);
}

test "status projection rebuild keeps selected node on same path key" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const before_path = app.changesNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", before_path);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const after_path = app.changesNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", after_path);
}

test "changes root expansion survives status projection and retains sticky diff target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var current = app_test_support.loadedDiffRootedNested();
    try current.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(loaded.visibleNodeCount() > 1);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[loaded.visibleNodeAt(0).?].kind);
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "changes root expansion status-first action refresh retains visible root children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var current = app_test_support.loadedDiffRootedNested();
    try current.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 3,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try installTestActionCursor(&app, std.testing.allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 1));

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(loaded.visibleNodeCount() > 1);
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "status load skips identical snapshot without rebuilding active tree" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.pages.changes.git_status.replace("/repo", &current);
    const tree_ptr = app.changesNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.changesNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
}

test "status refresh path skips identical snapshot without rebuilding active tree" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
        } },
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "?? aa\x00");
    try app.pages.changes.git_status.replace(roots.a, &current);
    const tree_ptr = app.changesNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    _ = try changes_read.testing.startStatusLoadTracked(app.changesRead(), &ctx.ctx, roots.a, .foreground, null, null);
    try std.testing.expect(app.pages.changes.git_status.repo_root != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    ctx.discardPendingTasks();

    const same = try git_status.StatusBundle.parseOwned(allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = app.pages.changes.status_load.generation,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.changesNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
}

test "status refresh drops snapshot when repo root changes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.b) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.b);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateChanges();
    defer app.pages.changes.git_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "?? old.zig\x00");
    try app.pages.changes.git_status.replace(roots.a, &current);

    _ = try changes_read.testing.startStatusLoadTracked(app.changesRead(), &ctx.ctx, roots.b, .foreground, null, null);

    try std.testing.expect(app.pages.changes.git_status.repo_root == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.git_status.document.entries.len);
}

test "finishStatusLoad keeps clean repository snapshot fresh" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
    };
    defer app.pages.changes.git_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const clean = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(!app.pages.changes.status_load.isPending());
    try std.testing.expectEqualStrings("/repo", app.pages.changes.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.git_status.document.entries.len);
}

test "background status failure retains display snapshot and marks action freshness stale" {
    var app: ReadHarness = .{ .allocator = std.testing.allocator };
    defer app.pages.changes.git_status.deinit();
    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);

    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .status));
    const generation = app.pages.changes.status_load.prepare(true);
    app.pages.changes.status_load.begin(cycle_id, .{});
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient status failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.changes.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.git_status.document.entries.len);
    try std.testing.expect(!app.pages.changes.status_load.isFresh());
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.changes.status_load.prepare(true);
    app.pages.changes.status_load.begin(null, .{});
    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.changes.status_load.isFresh());
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 2 } } },
    };
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.load.state == .idle);
}

test "auto reload tick skips while auxiliary cycle members or mouse selection are pending" {
    var app: ReadHarness = .{};
    app.pages.changes.auto_reload = .init(.inherit, .{});
    app.pages.changes.status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var status_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    status_ctx.init(std.testing.allocator, std.testing.io);
    defer status_ctx.deinit();
    try app.changesRead().autoReloadTick(&status_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), status_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.changes.status_load.pending = null;
    app.pages.changes.branch_status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var branch_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    branch_ctx.init(std.testing.allocator, std.testing.io);
    defer branch_ctx.deinit();
    app.redraw_plan = .{};
    try app.changesRead().autoReloadTick(&branch_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), branch_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.changes.branch_status_load.pending = null;
    app.pages.changes.changes_projection.pending = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        1,
        1,
    );
    var projection_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    projection_ctx.init(std.testing.allocator, std.testing.io);
    defer projection_ctx.deinit();
    app.redraw_plan = .{};
    try app.changesRead().autoReloadTick(&projection_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), projection_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    app.pages.changes.changes_projection.clearPending(std.testing.allocator);

    app.pages.changes.selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } };
    var selection_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    selection_ctx.init(std.testing.allocator, std.testing.io);
    defer selection_ctx.deinit();
    app.redraw_plan = .{};
    try app.changesRead().autoReloadTick(&selection_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), selection_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.changes.selection_owner = .none;
    const pending = beginAcceptedTestAction(&app, .stage_file);
    var action_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    action_ctx.init(std.testing.allocator, std.testing.io);
    defer action_ctx.deinit();
    app.redraw_plan = .{};
    try app.changesRead().autoReloadTick(&action_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), action_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    try std.testing.expect(app.acceptActionTerminal(pending));
    try installTestActionCursor(&app, std.testing.allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);
    var action_refresh_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    action_refresh_ctx.init(std.testing.allocator, std.testing.io);
    defer action_refresh_ctx.deinit();
    app.redraw_plan = .{};
    try app.changesRead().autoReloadTick(&action_refresh_ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), action_refresh_ctx.pendingTaskCount());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
}

test "stale diff result does not clear newer pending reload metadata" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 2 } } },
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    app.pages.changes.pending_reload = .{
        .generation = 2,
        .kind = .watch,
        .anchor = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = .{ .logical = 0 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
    };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.pending_reload != null);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.pending_reload.?.generation);
}

test "watch no-op diff load preserves session view state and staged hunk marks" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = .{ .logical = 3 },
                .diff_horizontal_scroll = 4,
                .sidebar_horizontal_scroll = 2,
            },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const mark_key = try currentTestSessionHunkMarkKey(&app, 0);
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);
    ownTestSourceRead(&app, 2, .watch);
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 3), app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(@as(usize, 4), app.pages.changes.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.sidebar_horizontal_scroll);
    try std.testing.expect(app.pages.changes.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expect(app.pages.changes.pending_reload == null);
}

test "changed watch reload restores acceptance-time navigation instead of launch anchor" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
            },
            .pending_reload = .{
                .generation = 2,
                .kind = .watch,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
                    .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
                    .selected_target_tag = .diff_file,
                    .visible_sidebar_row = 0,
                    .diff_cursor = .{ .metadata = 0 },
                    .diff_cursor_offset = 0,
                    .diff_scroll = .{ .logical = 0 },
                    .diff_horizontal_scroll = 0,
                    .sidebar_horizontal_scroll = 0,
                    .search_coordinate = null,
                },
            },
        } },
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    const acceptance_cursor = app.pages.changes.viewer.diff_cursor;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(acceptance_cursor, app.pages.changes.viewer.diff_cursor);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    const restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(acceptance_cursor, restore.original.diff_cursor);
}

test "unchanged recovery clears its source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{
                .generation = 2,
                .kind = .watch,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
                    .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
                    .selected_target_tag = .diff_file,
                    .visible_sidebar_row = 0,
                    .diff_cursor = .{ .hunk_header = 0 },
                    .diff_cursor_offset = 0,
                    .diff_scroll = .{ .logical = 0 },
                    .diff_horizontal_scroll = 0,
                    .sidebar_horizontal_scroll = 0,
                    .search_coordinate = null,
                },
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    _ = app.pages.changes.auto_reload.markSourceFailure("transient");
    app.pages.changes.status.setSourceReloadFailure(app.pages.changes.auto_reload.last_failure.?.digest, "auto reload failed: transient", .{});
    const before = app.changesNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());
    try std.testing.expectEqual(before, app.changesNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "unchanged source recovery preserves a newer auxiliary failure" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    _ = app.pages.changes.auto_reload.markSourceFailure("source transient");
    app.pages.changes.status.setSourceReloadFailure(app.pages.changes.auto_reload.last_failure.?.digest, "source failed", .{});
    app.setChangesStatus("status load failed: auxiliary transient", .{});
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "auxiliary failure followed by source failure clears only the recovered source message" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "auxiliary transient" },
    });
    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.changes.status.text());

    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.changes.status.text());

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "ordinary unchanged source completion suppresses redraw" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "changed loaded recovery clears its matching source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const old_fingerprint = content_fingerprint.Fingerprint.init("old");
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.changes.auto_reload.markSourceFailure("source transient");
    app.pages.changes.status.setSourceReloadFailure(app.pages.changes.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "empty recovery clears its matching source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const old_fingerprint = content_fingerprint.Fingerprint.init("old");
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.changes.auto_reload.markSourceFailure("source transient");
    app.pages.changes.status.setSourceReloadFailure(app.pages.changes.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "destructive action-result failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "foreground failed" },
    });
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    try std.testing.expect(app.changesNavigationView().activeLoadedDiffConst() == null);

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.changesNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "destructive manual failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .manual },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "manual failed" },
    });
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.changes.load.state == .failed);

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.changesNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "diff task start failure invalidates accepted source and next watch cannot return unchanged" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .{ .patch_file = "change.patch" } },
    };
    _ = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.fillTaskSlots(16);

    try std.testing.expectError(error.TaskLimitExceeded, changes_read.testing.startDiffLoadWithRepoRoot(app.changesRead(), &ctx.ctx, null, .{
        .clear_visible_state = true,
        .kind = .manual,
    }));
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.changes.load.state == .failed);

    ctx.discardPendingTasks();
    try changes_read.testing.startDiffLoadWithRepoRoot(app.changesRead(), &ctx.ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var task_message = try entries.fail(error.ConcurrencyUnavailable);
    defer task_message.deinitUndelivered(std.testing.allocator);
    const task = task_message.load_finished.changes.source;
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source == null);
    const generation = task.generation;

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.changesNavigationView().activeLoadedDiffConst().?.text);
}

test "watch failure retains display and blocks source-derived actions until success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload.acceptSource(fingerprint);
    const before = app.changesNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "transient failure" },
    });
    try std.testing.expectEqual(before, app.changesNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expect(!app.pages.changes.auto_reload.sourceIsActionable());

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsActionable());
    try std.testing.expectEqual(before, app.changesNavigationView().activeLoadedDiffConst().?.text.ptr);
}

test "changed watch result arriving during mouse selection defers apply until release" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.changes.deferred_source_apply != null);
    try std.testing.expectEqualStrings("old", app.changesNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle.?.pending.deferred_source_apply);

    app.changesNavigation().clearDiffSelection();
    try app.changesRead().applyDeferredSourceIfReady(&ctx.ctx);
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.changesNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}

test "deferred changed watch captures navigation when selection ends" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .metadata = 0 },
            },
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.changesReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.auto_reload = .init(.inherit, .{});
    const cycle_id = app.pages.changes.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.changes.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.changes.deferred_source_apply != null);
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore == null);

    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 0 };
    const navigation_at_apply = app.pages.changes.viewer.diff_cursor;
    app.changesNavigation().clearDiffSelection();
    try app.changesRead().applyDeferredSourceIfReady(&ctx.ctx);

    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expectEqual(navigation_at_apply, app.pages.changes.viewer.diff_cursor);
    const restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(navigation_at_apply, restore.original.diff_cursor);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}

test "anchored reload keeps cursor when search query is present" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = .{ .logical = 2 },
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    setDiffSearchQuery(&app, "new");
    app.pages.changes.search.match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } };
    app.pages.changes.search.match_offset = 4;
    app.pages.changes.load.generation = 2;
    try app.changesReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);

    var changed = app_test_support.loadedDiffOne();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expect(app.pages.changes.search.match != null);
}

test "manual reload restores anchor after visible state is cleared" {
    var current = app_test_support.loadedDiffTwo();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
                .diff_cursor = .{ .metadata = 0 },
                .diff_scroll = .{ .logical = 2 },
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    app.pages.changes.load.generation = 2;
    try app.changesReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);
    app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.state = .loading;

    var changed = app_test_support.loadedDiffTwo();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, app.pages.changes.viewer.diff_cursor);
}

test "changes root expansion survives manual reload and retains sticky target" {
    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var rooted_nodes = app_test_support.tree_rooted_nested_nodes;
    rooted_nodes[2].path_key = "a";
    rooted_nodes[3].path_key = "b";
    var current = app_test_support.loadedDiffRootedNested();
    current.tree = .{ .nodes = &rooted_nodes };
    current.text = "old";
    try current.rebuildVisibleNodes(current_arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(current_arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    app.pages.changes.load.generation = 2;
    try app.changesReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);
    app.changesReload().clearLoadedDiff(app.allocator);
    app.pages.changes.load.state = .loading;

    var changed = app_test_support.loadedDiffRootedNested();
    changed.tree = .{ .nodes = &rooted_nodes };
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[loaded.visibleNodeAt(0).?].kind);
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "watch no-op preserves selected path when status finishes before diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    app.pages.changes.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const selected_path = app.changesNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "watch no-op preserves selected path when status finishes after diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    app.pages.changes.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const selected_path = app.changesNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "finishDiffLoad records empty diff as no changes" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .empty,
    });

    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.changes.load.state.empty);
    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.load.generation);
}

test "finishDiffLoad projects earlier status snapshot into empty diff" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.changes.git_status.replace("/tmp/repo", &status_bundle);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .empty,
    });

    const loaded = app.changesNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.tree.nodes[1].target.status_entry);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target);
}

test "clean loaded status tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.changes.git_status.replace(roots.a, &current);
    try app.changesReload().createStatusOnlyLoadedSession(allocator, app.pages.changes.git_status.document);
    ownTestSourceRead(&app, 2, .initial);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });
    const empty_fingerprint = content_fingerprint.Fingerprint.init("");

    try std.testing.expect(app.changesNavigation().activeLoadedDiff() != null);
    try std.testing.expectEqual(@as(usize, 0), app.changesNavigation().activeLoadedDiff().?.document.files.len);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = clean },
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.git_status.document.entries.len);
    try std.testing.expect(app.changesNavigation().activeLoadedDiff() == null);
    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.changes.load.state.empty);
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());

    try changes_read.testing.startDiffLoadWithRepoRoot(app.changesRead(), &ctx.ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var entries = ctx.takeTask(0).?;
    defer entries.deinit();
    var task_message = try entries.fail(error.ConcurrencyUnavailable);
    defer task_message.deinitUndelivered(allocator);
    const task = task_message.load_finished.changes.source;
    try std.testing.expect(app.pages.changes.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));
    const generation = task.generation;

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = generation,
        .result = .{ .unchanged = empty_fingerprint },
    });
    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());
}

test "source failure before clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesReload().clearPendingReload(allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);
    ownTestSourceRead(&app, 2, .initial);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{ .identity = page.RequestIdentity.changes(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.changesNavigation().activeLoadedDiff() != null);

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expect(!app.pages.changes.auto_reload.sourceIsActionable());

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(app.changesNavigation().activeLoadedDiff() == null);
    try std.testing.expect(!app.pages.changes.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.changes.auto_reload.last_failure != null);
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.changes.status.text());
}

test "source failure after clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesReload().clearPendingReload(allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);
    ownTestSourceRead(&app, 2, .initial);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{ .identity = page.RequestIdentity.changes(0, 1), .generation = 2, .result = .empty });
    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });
    try std.testing.expect(app.pages.changes.auto_reload.sourceIsFresh());

    app.pages.changes.load.generation = 3;
    app.pages.changes.load.pending = .{ .diff_load = 3 };
    app.pages.changes.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "later source transient" },
    });

    try std.testing.expect(!app.pages.changes.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.changes.auto_reload.last_failure != null);
}

test "empty status result tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);
    try app.changesReload().createStatusOnlyLoadedSession(allocator, app.pages.changes.git_status.document);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.changesNavigation().activeLoadedDiff() != null);

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.git_status.document.entries.len);
    try std.testing.expect(app.changesNavigation().activeLoadedDiff() == null);
    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.changes.load.state.empty);
}

test "identical staged-only status keeps status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &current);
    try app.changesReload().createStatusOnlyLoadedSession(allocator, app.pages.changes.git_status.document);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .empty,
    });

    const loaded_after_diff = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_diff.document.files.len);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.git_status.document.entries.len);

    const same = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    const loaded_after_status = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_status.document.files.len);
    try std.testing.expect(loaded_after_status.visibleNodeCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.git_status.document.entries.len);
}

test "finishRepoDiscovery records no repository as empty state" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{
            .state = .loading,
            .pending = .{ .repo_discovery = 1 },
            .generation = 1,
        } } },
    };
    _ = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    defer app.repo_session.repo_state.deinit(std.testing.allocator);

    var pending = (try app.changesRead().finishRepoDiscovery(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try std.testing.allocator.dupe(u8, "/work"),
        } } },
    })) orelse return error.ExpectedDiscoveryCommit;
    defer pending.deinit(ctx.ctx.allocator());
    switch (pending.discovery orelse return error.ExpectedDiscoveryCommit) {
        .none => |none| try std.testing.expectEqualStrings("/work", none.current_root),
        else => return error.ExpectedNoRepositoryDiscovery,
    }

    // Simulate the repository coordinator accepting the owned command. The
    // read owner then applies only its page-local no-repository consequence.
    try app.changesRead().acceptRepoDiscoveryCommit(&ctx.ctx);

    try std.testing.expect(app.pages.changes.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_repository, app.pages.changes.load.state.empty);
}

test "finishDiffLoad copies and frees current failed message" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{ .load = .{ .generation = 1 } } },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ownTestSourceRead(&app, 1, .initial);

    const message = try std.testing.allocator.dupe(u8, " failed \n");
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .failed = message },
    });

    try std.testing.expect(app.pages.changes.load.state == .failed);
    try std.testing.expectEqualStrings("failed", app.pages.changes.load.state.failed.message);
}

test "action cursor waits for status terminal after matching source failure" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 1 },
            .status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try installTestActionCursor(&app, std.testing.allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 1));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 2));
    ownTestSourceRead(&app, 1, .action_result);

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .failed_static = "failed" },
    });
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "rejected old read terminals cannot consume action cursor members" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.changesNavigation().clearActionCursor(allocator);
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const old_epoch = app.pages.changes.repository_read_authority.epoch;
    app.pages.changes.load.generation = 1;
    app.pages.changes.load.pending = .{ .diff_load = 1 };
    app.pages.changes.pending_reload = .{
        .generation = 1,
        .read_epoch = old_epoch,
        .kind = .action_result,
    };
    app.pages.changes.status_load.generation = 2;
    app.pages.changes.status_load.pending = .{
        .generation = 2,
        .read_epoch = old_epoch,
    };

    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 1));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 2));
    app.pages.changes.repository_read_authority.epoch = old_epoch.next();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
        .read_epoch = old_epoch,
        .generation = 1,
        .result = .{ .failed_static = "old source" },
    });
    try std.testing.expect(app.pages.changes.action_cursor.captureCompletion(
        app.repo_session.repo_epoch,
        .source,
        1,
    ) != null);

    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, 1),
        .read_epoch = old_epoch,
        .generation = 2,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "old status" },
    });
    try std.testing.expect(app.pages.changes.action_cursor.captureCompletion(
        app.repo_session.repo_epoch,
        .status,
        2,
    ) != null);
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(app.pages.changes.load.pending == null);
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(app.pages.changes.status_load.pending == null);
    try std.testing.expect(app.changesNavigationView().activeLoadedDiffConst() != null);
}

const rooted_nested_action_refresh_diff =
    \\diff --git a/src/a b/src/a
    \\index 1..2 100644
    \\--- a/src/a
    \\+++ b/src/a
    \\@@ -1 +1 @@
    \\-old a
    \\+new a
    \\diff --git a/src/b b/src/b
    \\index 1..2 100644
    \\--- a/src/b
    \\+++ b/src/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\
;

fn buildRootedNestedActionBundle(allocator: std.mem.Allocator) !app_load.LoadedDiffBundle {
    var bundle = try app_load.buildLoadedBundle(allocator, rooted_nested_action_refresh_diff);
    errdefer bundle.deinit();
    const arena = bundle.arena.?.allocator();
    bundle.loaded.tree = try file_tree.buildWithOptions(
        arena,
        bundle.loaded.document,
        .{ .entries = &.{} },
        .{ .root = .{ .name = "repo" } },
    );
    try bundle.loaded.rebuildVisibleNodes(arena, false, .all);
    return bundle;
}

const LaterSidebarSelection = enum {
    directory,
    repo_root,
};

const SupersededRefreshOrder = enum {
    status_only,
    source_first,
    status_first,
};

fn expectLaterSidebarIdentity(app: *const ReadHarness, selection: LaterSidebarSelection) !void {
    const identity = app.changesNavigationView().selectedSidebarIdentity() orelse return error.ExpectedSidebarIdentity;
    switch (selection) {
        .directory => {
            try std.testing.expect(identity == .directory);
            try std.testing.expectEqualStrings("src", identity.directory);
        },
        .repo_root => try std.testing.expect(identity == .repo_root),
    }
    try std.testing.expectEqualStrings("src/a", app.changesNavigationView().selectedStagePathKey().?);
}

fn expectLaterDirectoryLikeSelectionAcrossRefresh(
    order: SupersededRefreshOrder,
    selection: LaterSidebarSelection,
) !void {
    const allocator = std.testing.allocator;
    var initial = try buildRootedNestedActionBundle(allocator);
    defer initial.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, "/repo");
    app.pages.changes.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);

    const activation_id = app.pageCoordinator().activateChanges();
    const loaded = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const selected_file = changes_navigation.findFileNodeByPathKey(loaded, "src/a") orelse return error.ExpectedSelectedFile;
    app.changesNavigation().selectSidebarNode(std.testing.allocator, loaded, selected_file);

    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    if (order != .status_only) {
        app.pages.changes.load.generation = 2;
        app.pages.changes.load.pending = .{ .diff_load = 2 };
        app.pages.changes.pending_reload = .{ .generation = 2, .kind = .action_result };
    }
    try installTestActionCursor(&app, allocator, .file, "src/a", 9);
    try promoteTestActionCursorWithRequirement(
        &app,
        9,
        if (order == .status_only) .status_only else .source_and_status,
    );
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));
    if (order != .status_only) {
        try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    }

    const selection_node = switch (selection) {
        .directory => changes_navigation.findNodeBySidebarIdentity(loaded, .{ .directory = "src" }),
        .repo_root => changes_navigation.findNodeBySidebarIdentity(loaded, .repo_root),
    } orelse return error.ExpectedDirectoryLikeNode;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    try applyChangesStateOnly(&app, allocator, .{ .sidebar_click_node = selection_node });
    try std.testing.expect(!app.pages.changes.action_cursor.hasRestoreAuthority());
    try expectLaterSidebarIdentity(&app, selection);

    if (order == .source_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_only or order == .status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    } else if (order == .source_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "later directory and root selections survive every hunk action refresh order" {
    for ([_]SupersededRefreshOrder{ .status_only, .source_first, .status_first }) |order| {
        for ([_]LaterSidebarSelection{ .directory, .repo_root }) |selection| {
            try expectLaterDirectoryLikeSelectionAcrossRefresh(order, selection);
        }
    }
}

fn expectDirectoryCursorAfterActionRefresh(status_first: bool) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    var current = app_test_support.loadedDiffRootedNested();
    try current.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    defer app.changesReload().clearPendingReload(allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(allocator);

    try installTestActionCursor(&app, allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    if (status_first) {
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
        try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 2,
            .result = .empty,
        });
    } else {
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 2,
            .result = .empty,
        });
        try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
    }

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    const loaded = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const directory_node = changes_navigation.findNodeBySidebarIdentity(
        loaded,
        .{ .directory = "src" },
    ) orelse return error.ExpectedDirectoryNode;
    try std.testing.expectEqual(file_tree.Node.Kind.directory, loaded.tree.nodes[directory_node].kind);
    try std.testing.expectEqual(directory_node, app.pages.changes.viewer.selected_node);
    // Directory restoration owns only the sidebar cursor. The body remains a
    // file/status target rather than being converted into a fake directory body.
    try std.testing.expect(app.pages.changes.viewer.selected_target != null);
}

test "source-first action refresh restores directory after exact status completion" {
    try expectDirectoryCursorAfterActionRefresh(false);
}

test "status-first action refresh restores directory after exact source completion" {
    try expectDirectoryCursorAfterActionRefresh(true);
}

fn expectTerminalActionRefreshRepublishesFileSearch(status_first: bool) !void {
    const allocator = std.testing.allocator;
    var initial = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
    defer initial.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app.pages.changes.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer app.changesReload().clearPendingReload(allocator);
    defer app.changesReload().clearLoadedDiff(allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, "?? legacy.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &old_status);
    try app.changesReload().applyStatusProjection(allocator, false, .accepted_status);
    app.pages.changes.file_search.mode = true;
    try app.pages.changes.file_search.input.insertSlice("legacy");
    app.changesNavigation().rebuildFileSearchProjection(allocator);
    try std.testing.expectEqual(
        changes_page.file_search.TargetKind.status_only,
        app.pages.changes.file_search.focusedCandidate().?.target_kind,
    );

    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.changes.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    if (status_first) {
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
        try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.changes.file_search.projection_available);

        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
    } else {
        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.changes.file_search.projection_available);

        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
    }

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    const loaded = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    for (loaded.tree.nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.path_key, "legacy.zig"));
    }
    try std.testing.expect(app.pages.changes.file_search.mode);
    try std.testing.expectEqualStrings("legacy", app.pages.changes.file_search.input.slice());
    try std.testing.expect(app.pages.changes.file_search.projection_available);
    try std.testing.expect(app.pages.changes.file_search.no_match);
    try std.testing.expect(app.pages.changes.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.file_search.candidates.len);
    try std.testing.expectEqual(
        app.pages.changes.accepted_sidebar_revision,
        app.pages.changes.file_search.basis.?.accepted_sidebar_revision,
    );
}

test "source-first action refresh republishes file search from terminal empty status tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(false);
}

test "status-first action refresh republishes file search from terminal source tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(true);
}

test "inactive Changes consumes matching action refresh terminals without shell redraw" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .active_page = .repository,
        .pages = .{ .changes = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = allocator,
    };
    defer app.changesReload().clearPendingReload(allocator);
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.changesNavigation().clearActionCursor(allocator);
    try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source failed" },
    });
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

const ActionCursorPeerState = enum {
    pending,
    terminal,
};

test "source apply allocation failure closes exact action cursor member for pending and terminal peers" {
    const backing = std.testing.allocator;
    for ([_]ActionCursorPeerState{ .pending, .terminal }) |peer_state| {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        var app: ReadHarness = .{
            .allocator = allocator,
            .config = .{ .source = .unstaged },
            .pages = .{ .changes = .{
                .load = .{ .generation = 1, .pending = .{ .diff_load = 1 } },
                .status_load = if (peer_state == .pending)
                    .{ .generation = 2, .pending = .{ .generation = 2 } }
                else
                    .{},
            } },
        };
        const activation_id = app.pageCoordinator().activateChanges();
        defer app.changesReload().clearLoadedDiff(allocator);
        defer app.pages.changes.git_status.deinit();
        defer app.changesNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.changes.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 2, false));
        }
        ownTestSourceRead(&app, 1, .action_result);
        app.pages.changes.activation.queueRevalidation();

        // applySourceFailure has already consumed the task generation before
        // storing its owned diagnostic. Fail that allocation and prove the
        // captured completion still becomes a failure terminal.
        failing.fail_index = failing.alloc_index;
        var failing_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        failing_ctx.init(allocator, std.testing.io);
        defer failing_ctx.deinit();
        try std.testing.expectError(error.OutOfMemory, app.changesRead().finishDiffLoad(failing_ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 1,
            .result = .{ .failed_static = "source apply failed" },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(changes_page.action_cursor.Terminal.failed, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
            peer_ctx.init(backing, std.testing.io);
            defer peer_ctx.deinit();
            try app.changesRead().finishStatusLoad(peer_ctx.ctx.allocator(), .{
                .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
                .generation = 2,
                .repo_root = try backing.dupe(u8, "/repo"),
                .result = .{ .failed_static = "status failed" },
            });
        }

        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
        try std.testing.expect(app.pages.changes.activation.hasQueuedFullRevalidation());
    }
}

test "status apply allocation failure closes exact action cursor member for pending and terminal peers" {
    const backing = std.testing.allocator;
    for ([_]ActionCursorPeerState{ .pending, .terminal }) |peer_state| {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        var app: ReadHarness = .{
            .allocator = allocator,
            .config = .{ .source = .unstaged },
            .pages = .{ .changes = .{
                .load = if (peer_state == .pending)
                    .{ .generation = 1, .pending = .{ .diff_load = 1 } }
                else
                    .{},
                .status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
            } },
        };
        const activation_id = app.pageCoordinator().activateChanges();
        defer app.changesReload().clearLoadedDiff(allocator);
        defer app.pages.changes.git_status.deinit();
        defer app.changesNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.changes.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 1, false));
        } else {
            ownTestSourceRead(&app, 1, .action_result);
        }
        app.pages.changes.activation.queueRevalidation();

        var bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
        var bundle_owned = true;
        defer if (bundle_owned) bundle.deinit();
        const repo_root = try allocator.alloc(u8, 64 * 1024);
        var repo_root_owned = true;
        defer if (repo_root_owned) allocator.free(repo_root);
        @memset(repo_root, 'r');
        // GitStatusState.replace must copy this root into the result arena.
        // Its size forces a fresh arena allocation, which is the next and
        // deliberately failing allocation below.
        failing.fail_index = failing.alloc_index;
        var failing_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
        failing_ctx.init(allocator, std.testing.io);
        defer failing_ctx.deinit();
        bundle_owned = false;
        repo_root_owned = false;
        try std.testing.expectError(error.OutOfMemory, app.changesRead().finishStatusLoad(failing_ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .repo_root = repo_root,
            .result = .{ .loaded = bundle },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.changes.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(changes_page.action_cursor.Terminal.pending, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(changes_page.action_cursor.Terminal.failed, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
            peer_ctx.init(backing, std.testing.io);
            defer peer_ctx.deinit();
            try app.changesRead().finishDiffLoad(peer_ctx.ctx.allocator(), .{
                .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
                .generation = 1,
                .result = .{ .failed_static = "source failed" },
            });
        }

        try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
        try std.testing.expect(!changes_read.testing.readBusy(app.changesRead()));
        try std.testing.expect(app.pages.changes.activation.hasQueuedFullRevalidation());
    }
}

fn expectStatusOnlyHunkRefreshPath(later_selection: bool) !void {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearLoadedDiff(allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(allocator);

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    app.pages.changes.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));
    if (later_selection) {
        try applyChangesStateOnly(&app, allocator, .select_next_file);
        try std.testing.expectEqualStrings("b", app.changesNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.changes.action_cursor.hasRestoreAuthority());
    }

    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status },
    });
    status = undefined;

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(if (later_selection) "b" else "a", app.changesNavigationView().selectedStagePathKey().?);
}

test "mixed and final status-only hunk transitions retain their exact selected path" {
    try expectStatusOnlyHunkRefreshPath(false);
}

test "final hunk stage retains exact path through cached projection acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffFileOneFirst();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadStateWithArena(arena, loaded),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    // The neighboring file `b` is row zero; path restoration must
                    // not fall back to that ordinal when `a` becomes status-only.
                    .selected_node = 1,
                },
            },
        },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    const activation_id = app.pageCoordinator().activateChanges();
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 0);
    app.pages.changes.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 1);
    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = staged_status },
    });
    staged_status = undefined;

    // The status snapshot changes before the watched unstaged source catches
    // up, so `a` remains the selected source file for this brief interval.
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    app.pages.changes.load.generation = 10;
    app.pages.changes.load.pending = .{ .diff_load = 10 };
    try app.changesReload().beginPendingReload(allocator, 10, .watch);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 10,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff) },
    });

    // The successor source no longer contains `a`; status projection now
    // materializes its staged-only row and reapplies the retained path anchor.
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);
    const current_loaded = app.changesNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const original_a_node = changes_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const original_b_node = changes_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    const tree_allocator = app.changesNavigation().loadArenaAllocator() orelse return error.ExpectedLoadArena;
    const reordered_nodes = try tree_allocator.alloc(file_tree.Node, 2);
    reordered_nodes[0] = current_loaded.tree.nodes[original_b_node];
    reordered_nodes[1] = current_loaded.tree.nodes[original_a_node];
    current_loaded.tree.nodes = reordered_nodes;
    try current_loaded.rebuildVisibleNodes(tree_allocator, false, .all);
    app.pages.changes.viewer.selected_node = 1;
    const a_node = changes_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const b_node = changes_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    try std.testing.expect(b_node < a_node);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    try app.changesRead().ensureProjection(&ctx.ctx);
    const pending = app.pages.changes.changes_projection.pending orelse return error.ExpectedCachedProjection;
    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, pending.kind);
    try std.testing.expectEqualStrings("a", pending.path_key);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);

    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    ctx.discardPendingTasks();

    const result_request = try app_changes_projection.testing.cloneRequestWithRootIdentity(
        allocator,
        pending.identity,
        pending.id,
        pending.repo_root,
        pending.path_key,
        pending.kind,
        pending.source_kind,
        pending.source_session_revision,
        pending.status_snapshot_revision,
        pending.root_identity.?,
    );
    try app.changesRead().finishProjectionLoad(ctx.ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.changesNavigationView().activeCachedDiffProjection() != null);
    try std.testing.expectEqualStrings("a", app.changesNavigationView().selectedStagePathKey().?);
}

test "later keyboard selection wins while status-only hunk refresh completes" {
    try expectStatusOnlyHunkRefreshPath(true);
}

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

fn expectSelectionAcrossSourceAndStatus(status_first: bool, later_selection: bool) !void {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateChanges();
    defer app.changesReload().clearPendingReload(allocator);
    defer app.changesReload().clearLoadedDiff(allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(allocator);

    app.pages.changes.load.generation = 2;
    app.pages.changes.load.pending = .{ .diff_load = 2 };
    app.pages.changes.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.changes.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    if (later_selection) {
        try applyChangesStateOnly(&app, allocator, .select_next_file);
        try std.testing.expectEqualStrings("b", app.changesNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.changes.action_cursor.hasRestoreAuthority());
    }
    const expected_path = if (later_selection) "b" else "a";

    if (status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try std.testing.expectEqualStrings(expected_path, app.changesNavigationView().selectedStagePathKey().?);
    }

    const successor = try app_load.buildLoadedBundle(allocator, reordered_action_refresh_diff);
    try app.changesRead().finishDiffLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
        .generation = 2,
        .result = .{ .loaded = successor },
    });
    try std.testing.expectEqualStrings(expected_path, app.changesNavigationView().selectedStagePathKey().?);

    if (!status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
            .identity = page.RequestIdentity.changes(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
    }

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(expected_path, app.changesNavigationView().selectedStagePathKey().?);
}

test "cached hunk unstage retains exact path through source-first refresh" {
    try expectSelectionAcrossSourceAndStatus(false, false);
}

test "cached hunk unstage retains exact path through status-first refresh" {
    try expectSelectionAcrossSourceAndStatus(true, false);
}

test "later selection survives source-first hunk action refresh with reordered files" {
    try expectSelectionAcrossSourceAndStatus(false, true);
}

test "later selection survives status-first hunk action refresh with reordered files" {
    try expectSelectionAcrossSourceAndStatus(true, true);
}

test "action cursor waits for the exact status member after source is terminal" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.changes.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 2, true));
    app.pages.changes.status_load.pending = .{ .generation = 1 };

    // The source half may complete first. Retained pre-action status is not a
    // coherent final projection and therefore cannot consume the owner.
    try app.changesReload().applyStatusProjection(std.testing.allocator, false, .accepted_source);
    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());

    app.pages.changes.status_load.pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try app.changesReload().applyStatusProjection(std.testing.allocator, false, .accepted_status);
    try std.testing.expect(app.pages.changes.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    try std.testing.expect(app.changesNavigation().finalizeActionCursor(std.testing.allocator));

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "action cursor survives exact status projection while source member is pending" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.changes.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    app.pages.changes.load.pending = .{ .diff_load = app.pages.changes.load.generation + 1 };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try app.changesReload().applyStatusProjection(std.testing.allocator, false, .accepted_status);

    try std.testing.expect(app.pages.changes.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
}

test "action cursor closes after status completion when source failed before generation" {
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.changesReload().clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.changesNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "missing.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.changes.action_cursor.failMemberBeforeStart(9, .source));
    try std.testing.expect(app.pages.changes.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.changesRead().finishStatusLoad(ctx.ctx.allocator(), .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "clearLoadedDiff clears session staged hunk marks" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.staged_hunks.deinit(allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.changes.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    try std.testing.expect(app.pages.changes.staged_hunks.containsExact("/repo", "a", mark_key));

    app.changesReload().clearLoadedDiff(app.allocator);

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.staged_hunks.items.items.len);
}

test "queued Changes Git reads retain the accepted root across path replacement" {
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

    try runChangesTestGit(io, accepted, &.{ "git", "init", "--initial-branch=main" });
    try accepted.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runChangesTestGit(io, accepted, &.{ "git", "add", "tracked.txt" });
    try runChangesTestGit(io, accepted, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try accepted.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\nA_UNSTAGED\n" });
    try accepted.writeFile(io, .{ .sub_path = "a-staged.txt", .data = "one\ntwo\n" });
    try runChangesTestGit(io, accepted, &.{ "git", "add", "a-staged.txt" });
    try accepted.writeFile(io, .{ .sub_path = "shared-untracked.txt", .data = "A_ONE\nA_TWO\n" });

    try runChangesTestGit(io, replacement, &.{ "git", "init", "--initial-branch=replacement" });
    try replacement.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runChangesTestGit(io, replacement, &.{ "git", "add", "tracked.txt" });
    try runChangesTestGit(io, replacement, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try replacement.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\nB_UNSTAGED\nB_ONLY\n" });
    try replacement.writeFile(io, .{ .sub_path = "b-staged.txt", .data = "one\ntwo\nthree\n" });
    try runChangesTestGit(io, replacement, &.{ "git", "add", "b-staged.txt" });
    try replacement.writeFile(io, .{ .sub_path = "shared-untracked.txt", .data = "B_ONE\nB_TWO\nB_THREE\nB_FOUR\n" });

    const slot_path = try tmp.dir.realPathFileAlloc(io, "slot", allocator);
    defer allocator.free(slot_path);
    const slot_git_dir = try std.fs.path.join(allocator, &.{ slot_path, ".git" });
    defer allocator.free(slot_git_dir);
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("GIT_DIR", slot_git_dir);
    try parent_environment.put("GIT_WORK_TREE", slot_path);

    var app = try mutationFenceRepoTestApp(allocator, slot_path);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    app.env_map = &parent_environment;
    var ctx: chasen.testing.TestCtx(ReadHarness.Msg) = undefined;
    ctx.init(allocator, io);
    defer ctx.deinit();
    try app.changesRead().startDiffLoad(&ctx.ctx, .manual);
    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    var queued = [_]chasen.testing.TestTask(ReadHarness.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&queued) |*task| task.deinit();

    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);

    const status_message = try queued[0].run();
    const branch_message = try queued[1].run();
    const source_message = try queued[2].run();

    var status_finished = switch (status_message) {
        .load_finished => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .status => |finished| finished,
                else => return error.ExpectedStatusRead,
            },
            else => return error.ExpectedStatusRead,
        },
        else => return error.ExpectedStatusRead,
    };
    defer status_finished.deinit(allocator);
    var branch_finished = switch (branch_message) {
        .load_finished => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .branch_status => |finished| finished,
                else => return error.ExpectedBranchStatusRead,
            },
            else => return error.ExpectedBranchStatusRead,
        },
        else => return error.ExpectedBranchStatusRead,
    };
    defer branch_finished.deinit(allocator);
    var source_finished = switch (source_message) {
        .load_finished => |load| switch (load) {
            .changes => |changes| switch (changes) {
                .source => |finished| finished,
                else => return error.ExpectedSourceRead,
            },
            else => return error.ExpectedSourceRead,
        },
        else => return error.ExpectedSourceRead,
    };
    defer source_finished.deinit(allocator);

    const source_bundle = switch (source_finished.result) {
        .loaded => |bundle| bundle,
        else => return error.ExpectedLoadedSource,
    };
    try std.testing.expect(std.mem.indexOf(u8, source_bundle.loaded.text, "A_UNSTAGED") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_bundle.loaded.text, "B_UNSTAGED") == null);

    const status_bundle = switch (status_finished.result) {
        .loaded => |bundle| bundle,
        else => return error.ExpectedLoadedStatus,
    };
    var saw_a_staged = false;
    var saw_b_staged = false;
    for (status_bundle.document.entries) |entry| {
        const key = entry.canonicalPathKey() orelse continue;
        saw_a_staged = saw_a_staged or std.mem.eql(u8, key, "a-staged.txt");
        saw_b_staged = saw_b_staged or std.mem.eql(u8, key, "b-staged.txt");
    }
    try std.testing.expect(saw_a_staged);
    try std.testing.expect(!saw_b_staged);
    var saw_a_numstat = false;
    var saw_a_untracked_stats = false;
    for (status_bundle.document.line_stats) |entry| {
        if (std.mem.eql(u8, entry.path_key, "a-staged.txt")) {
            saw_a_numstat = true;
            try std.testing.expectEqual(@as(usize, 2), entry.stats.added);
            try std.testing.expectEqual(@as(usize, 0), entry.stats.removed);
        }
        if (std.mem.eql(u8, entry.path_key, "shared-untracked.txt")) {
            saw_a_untracked_stats = true;
            try std.testing.expectEqual(@as(usize, 2), entry.stats.added);
            try std.testing.expectEqual(@as(usize, 0), entry.stats.removed);
        }
        try std.testing.expect(!std.mem.eql(u8, entry.path_key, "b-staged.txt"));
    }
    try std.testing.expect(saw_a_numstat);
    try std.testing.expect(saw_a_untracked_stats);
    const branch_bundle = switch (branch_finished.result) {
        .loaded => |bundle| bundle,
        else => return error.ExpectedLoadedBranchStatus,
    };
    try std.testing.expectEqualStrings("main", branch_bundle.status.branchName().?);
    try std.testing.expect(!std.mem.eql(u8, "replacement", branch_bundle.status.branchName().?));
}
