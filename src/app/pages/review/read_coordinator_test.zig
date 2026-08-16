//! Owner-local contract tests for Review read coordination.
//!
//! The harness composes only Review page state, repository identity, action
//! fence state, and redraw outputs. It deliberately does not import or model
//! the root `App` dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../../actions.zig");
const action_lifecycle = @import("../../workflow/action_lifecycle.zig");
const app_auto_reload = @import("../../auto_reload.zig");
const diff_surface = @import("../../diff_surface.zig");
const review_authority = @import("../../diff_surface/authority.zig");
const git_ops = @import("../../git_ops.zig");
const app_load = @import("../../load.zig");
const app_load_state = @import("../../load_state.zig");
const app_message = @import("../../message.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const app_review_projection = @import("../../review_projection.zig");
const app_projection_component = @import("../../projection_component.zig");
const app_shell_layout = @import("../../shell_layout.zig");
const app_test_support = @import("../../test_support.zig");
const review_page = @import("../review.zig");
const review_action_fence = @import("action_fence.zig");
const review_message = @import("message.zig");
const review_navigation = @import("navigation.zig");
const review_operations = @import("operations.zig");
const review_read = @import("read_coordinator.zig");
const review_reload = @import("reload.zig");
const review_update = @import("update.zig");
const review_selection_model = @import("../../diff_surface/selection.zig");

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
const review_session_state = @import("../../../review_session/state.zig");
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
const ReviewProjectionFinished = app_load.ReviewProjectionFinished;
const ReviewProjectionTask = app_load.ReviewProjectionTask(app_message.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(app_message.Msg);
const ToggleStageOperation = git_ops.ToggleStageOperation;

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

fn runReviewTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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
    review: review_page.ReviewPageState = .{},
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

const ReviewActivationHarness = struct {
    review: *review_page.ReviewPageState,
    repo: repo_session.View,
    source: diff_source.SourceMode,

    fn activateReview(self: ReviewActivationHarness) u64 {
        const source_member: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(self.source))
            switch (self.review.load.state) {
                .loaded, .empty => .immutable,
                .loading => .pending,
                .failed => .failed,
                .idle => .pending,
            }
        else
            .pending;
        const auxiliary: review_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(self.source) and self.repo.activeRoot() != null)
            .pending
        else
            .unavailable;
        return self.review.activation.activate(self.repo.epoch(), source_member, auxiliary, auxiliary);
    }
};

const ReadHarness = struct {
    pub const Msg = app_message.Msg;

    active_page: page.Id = .review,
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

    fn pageCoordinator(self: *ReadHarness) ReviewActivationHarness {
        return .{
            .review = &self.pages.review,
            .repo = self.repoSessionView(),
            .source = self.config.source,
        };
    }

    fn reviewNavigation(self: *ReadHarness) review_navigation.Controller {
        return .{
            .page = &self.pages.review,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
            .diagnostics = .{ .target = &self.pages.review.status },
        };
    }

    fn reviewNavigationView(self: *const ReadHarness) review_navigation.View {
        return .{
            .page = &self.pages.review,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = self.bodyLayout(),
        };
    }

    fn reviewReload(self: *ReadHarness) review_reload.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
        };
    }

    fn reviewReloadView(self: *const ReadHarness) review_reload.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
        };
    }

    fn reviewActionFence(self: *ReadHarness) review_action_fence.Controller {
        return .{
            .read_authority = &self.pages.review.repository_read_authority,
            .activation = &self.pages.review.activation,
            .action_cursor = &self.pages.review.action_cursor,
            .auto_reload = &self.pages.review.auto_reload,
            .review_projection = &self.pages.review.review_projection,
            .deferred_projection_apply = &self.pages.review.deferred_projection_apply,
        };
    }

    fn reviewRead(self: *ReadHarness) review_read.Controller {
        return .{
            .page_state = &self.pages.review,
            .fence = self.reviewActionFence().view(),
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

    fn reviewOperations(self: *const ReadHarness) review_operations.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.review.activation.state,
        };
    }

    fn reviewOperationController(self: *ReadHarness) review_operations.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .view_state = self.reviewOperations(),
        };
    }

    fn actionLifecycle(self: *ReadHarness) action_lifecycle.Controller {
        return .{
            .runtime = &self.action_runtime,
            .fence = self.reviewActionFence(),
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

    fn setReviewStatus(self: *ReadHarness, comptime fmt: []const u8, args: anytype) void {
        self.pages.review.status.set(fmt, args);
    }
};

/// Runs only the Review-owned portion of the shell's post-message boundary.
/// Tests call this explicitly when the contract under test spans a completion
/// and the next queued read; it is intentionally not a general App dispatcher.
fn runReadCoordinationTail(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
) !void {
    app.reviewRead().retireSupersededActionCursor(ctx, app.action_runtime.view().generation());
    try app.reviewRead().applyDeferredSourceIfReady(ctx);
    try app.reviewRead().applyDeferredProjectionIfReady(ctx);
    try app.reviewRead().maybeStartQueuedRevalidation(ctx);
    const queued_before_projection = app.reviewRead().hasQueuedFullRevalidation();
    if (app.active_page == .review) try app.reviewRead().ensureProjection(ctx);
    if (!queued_before_projection and app.reviewRead().hasQueuedFullRevalidation()) {
        try app.reviewRead().maybeStartQueuedRevalidation(ctx);
    }
}

fn finishOwnedReviewRead(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    message: ReadHarness.Msg,
) !void {
    const finished = switch (message) {
        .load_finished => |value| value,
        else => return error.ExpectedReviewReadCompletion,
    };
    switch (finished) {
        .review => |review_finished| switch (review_finished) {
            .source => |value| try app.reviewRead().finishDiffLoad(ctx.allocator(), value),
            .status => |value| try app.reviewRead().finishStatusLoad(ctx.allocator(), value),
            .branch_status => |value| app.reviewRead().finishBranchStatusLoad(ctx.allocator(), value),
            .projection => |value| try app.reviewRead().finishProjectionLoad(ctx.allocator(), value),
            .projection_syntax => |value| app.reviewRead().finishGeneratedProjectionSyntax(ctx.allocator(), value),
        },
        else => return error.ExpectedReviewReadCompletion,
    }
    try runReadCoordinationTail(app, ctx);
}

fn actionTargetsCurrentReview(
    app: *const ReadHarness,
    repo_root: []const u8,
) bool {
    return app.active_page == .review and
        app.pages.review.activation.currentIdentity() != null and
        !diff_source.sourceIsOneShotInput(app.config.source) and
        app.repoSessionView().activeRootMatches(repo_root);
}

/// Completes the exact action/fence handshake, applies an optional successful
/// Review-local outcome, then runs the read-owned scheduling tail. A null
/// outcome represents a failed action whose only Review consequence is cursor
/// cleanup plus any already-queued terminal fallback.
fn finishTestAction(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    pending: app_actions.PendingAction,
    repo_root: []const u8,
    outcome: ?review_operations.AcceptedActionOutcome,
) !bool {
    const active_matches = actionTargetsCurrentReview(app, repo_root);
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
        const applied = app.reviewOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            accepted,
            active_matches,
        );
        try app.reviewRead().applyActionOutcome(ctx, pending, active_matches, applied.reload);
    } else {
        _ = app.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), pending.generation);
    }
    try runReadCoordinationTail(app, ctx);
    return true;
}

fn applyReviewStateOnly(
    app: *ReadHarness,
    allocator: std.mem.Allocator,
    message: review_message.Msg,
) !void {
    var applied = try (review_update.Controller{
        .navigation = app.reviewNavigation(),
    }).apply(allocator, message);
    defer applied.deinit(allocator);
    try std.testing.expect(applied.command == null);
    if (applied.capture_display_override) {
        try app.reviewRead().captureDisplayOverride(allocator);
    }
}

fn ownTestSourceRead(app: *ReadHarness, generation: u64, kind: review_page.ReloadKind) void {
    app.pages.review.load.generation = generation;
    app.pages.review.load.pending = .{ .diff_load = generation };
    if (app.pages.review.pending_reload) |*pending| {
        std.debug.assert(pending.generation == generation);
        pending.read_epoch = app.pages.review.repository_read_authority.epoch;
    } else {
        app.pages.review.pending_reload = .{
            .generation = generation,
            .read_epoch = app.pages.review.repository_read_authority.epoch,
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
    kind: review_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repoSessionView().activeIdentity() orelse test_action_root_identity;
    var prepared = try app.reviewNavigation().prepareActionCursor(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        kind,
        path_key,
    );
    app.reviewNavigation().installActionCursor(allocator, &prepared, action_generation);
}

fn promoteTestActionCursor(app: *ReadHarness, action_generation: u64) !void {
    return promoteTestActionCursorWithRequirement(app, action_generation, .source_and_status);
}

fn promoteTestActionCursorWithRequirement(
    app: *ReadHarness,
    action_generation: u64,
    requirement: review_page.action_cursor.RefreshRequirement,
) !void {
    const owner = app.pages.review.action_cursor.owner orelse return error.ExpectedActionCursorOwner;
    try std.testing.expect(app.pages.review.action_cursor.promote(
        action_generation,
        owner.repo_epoch,
        owner.root_identity,
        requirement,
    ));
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
    const ready = switch (app.pages.review.review_projection.displayed) {
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
    source_read_epoch: review_page.repository_read_authority.ReviewRepositoryReadEpoch,
    source_generation: u64,
    source_cycle_id: ?u64,
    status_identity: page.RequestIdentity,
    status_read_epoch: review_page.repository_read_authority.ReviewRepositoryReadEpoch,
    status_generation: u64,
    status_cycle_id: ?u64,
    branch_identity: page.RequestIdentity,
    branch_read_epoch: review_page.repository_read_authority.ReviewRepositoryReadEpoch,
    branch_generation: u64,
    branch_cycle_id: ?u64,
};

fn canonicalPublicationTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !ReadHarness {
    var app: ReadHarness = .{
        .allocator = allocator,
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .auto_reload = .init(.enabled, .{}, .unstaged),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 1,
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.review.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try app.pages.review.git_status.replace(repo_root, &status);
    app.pages.review.status_load.markSuccess();
    acceptTestSource(&app);
    const identity = app.pages.review.activation.currentIdentity() orelse return error.ExpectedReviewActivation;
    var initial_bundle = try testCombinedHunkBundle(allocator);
    initial_bundle.presentation.content_token =
        diff_presentation_identity.ContentToken.init(app.pages.review.source_session_revision);
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = try app_review_projection.testing.cloneRequest(
            allocator,
            identity,
            1,
            repo_root,
            "a",
            .combined_hunks,
            .unstaged,
            app.pages.review.source_session_revision,
            app.pages.review.status_snapshot_revision,
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
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
        .pages = .{ .review = .{
            .auto_reload = .init(.enabled, .{}, .unstaged),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 1,
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.review.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var source = try app_load.buildLoadedBundle(allocator, canonical_publication_combined_diff);
    errdefer source.deinit();
    app.pages.review.load.replaceLoaded(allocator, .{
        .arena = source.takeArena(),
        .loaded = source.loaded,
        .reviewed_files_owned = false,
    });
    var status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try app.pages.review.git_status.replace(repo_root, &status);
    app.pages.review.status_load.markSuccess();
    acceptTestSource(&app);

    const identity = app.pages.review.activation.currentIdentity() orelse return error.ExpectedReviewActivation;
    var candidate = try canonicalPublicationReuseCandidate(
        allocator,
        app.pages.review.status_snapshot_revision,
    );
    defer candidate.deinit();
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = try app_review_projection.testing.cloneRequest(
            allocator,
            identity,
            1,
            repo_root,
            "a",
            .combined_hunks,
            .unstaged,
            app.pages.review.source_session_revision,
            app.pages.review.status_snapshot_revision,
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
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .auto_reload = .init(.enabled, .{}, .unstaged),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
                .diff_scroll = 1,
                .diff_horizontal_scroll = 2,
                .sidebar_horizontal_scroll = 1,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    errdefer app.pages.review.deinit(allocator);
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);

    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.review.git_status.replace(repo_root, &status);
    app.pages.review.status_load.markSuccess();
    acceptTestSource(&app);
    try std.testing.expect(app.pages.review.review_projection.displayed == .idle);
    try std.testing.expect(app.pages.review.review_projection.pending == null);
    try std.testing.expect(app.reviewNavigationView().displayedReviewBody() == .primary);
    return app;
}

fn canonicalPublicationReuseCandidate(
    allocator: std.mem.Allocator,
    status_snapshot_revision: u64,
) !app_review_projection.CombinedReuseCandidate {
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
    const candidate: app_review_projection.CombinedReuseCandidate = .{
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
) !app_review_projection.StagedOnlyReuseCandidate {
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
    const candidate: app_review_projection.StagedOnlyReuseCandidate = .{
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
) !review_selection_model.ReviewContentToken {
    const displayed = app.reviewNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    const token = app.reviewNavigationView().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 1, .line_index = 0 },
        .focus = .{ .hunk_index = 1, .line_index = 0 },
        .moved = true,
    };
    app.pages.review.completed_selection = try review_selection_model.buildParsed(
        allocator,
        token,
        displayed,
        selection,
    );
    try app.pages.review.staged_hunks.addExact(allocator, repo_root, "a", .{
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
    const outcome: review_operations.AcceptedActionOutcome = switch (action) {
        .stage_file => .stage_file,
        .unstage_file => .unstage_file,
        .discard_file => .{ .discard_file = .{ .repo_root = repo_root, .path = "a" } },
        .commit => .{ .commit = .{ .repo_root = repo_root } },
    };
    try std.testing.expect(try finishTestAction(app, ctx, pending, repo_root, outcome));
}

fn takeCanonicalPublicationReads(
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(entries[1].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
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
    StatusLoadTask.destroy(status_task, allocator);
    BranchStatusLoadTask.destroy(branch_task, allocator);
    DiffLoadTask.destroy(source_task, allocator);
    return reads;
}

fn startCanonicalPublicationWatch(
    app: *ReadHarness,
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
) !CanonicalPublicationReads {
    try app.reviewRead().autoReloadTick(ctx);
    const reads = try takeCanonicalPublicationReads(ctx, allocator);
    const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
    try std.testing.expectEqual(@as(?u64, cycle_id), reads.status_cycle_id);
    try std.testing.expectEqual(@as(?u64, cycle_id), reads.branch_cycle_id);
    const cycle = app.pages.review.auto_reload.background_cycle orelse
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
    const deferred = app.pages.review.deferred_source_apply orelse
        return error.ExpectedDeferredSource;
    try std.testing.expectEqual(cycle_id, deferred.cycle_id);
    const cycle = app.pages.review.auto_reload.background_cycle orelse
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
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
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
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
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
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
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
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
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
    app.reviewRead().finishBranchStatusLoad(ctx.allocator(), .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .failed_static = "test branch status terminal" },
    });
}

fn takeCanonicalPublicationProjectionRequest(
    ctx: *chasen.Ctx(ReadHarness.Msg),
    allocator: std.mem.Allocator,
) !app_review_projection.Request {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *ReviewProjectionTask = @ptrCast(@alignCast(entries[0].ctx));
    const request = task.request;
    task.request = undefined;
    task.environment.deinit();
    task.root.deinit();
    allocator.destroy(task);
    return request;
}

fn canonicalPublicationFinalBundle(
    allocator: std.mem.Allocator,
    request: app_review_projection.Request,
) !app_review_projection.CombinedHunkBundle {
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
    const retained = app.reviewNavigationView().activeCombinedProjection() orelse
        return error.ExpectedRetainedCanonicalPublication;
    try std.testing.expectEqual(expected_hunks, retained.displayFile().hunks.ptr);
}

fn expectRetainedOrdinaryPrimaryPublication(
    app: *const ReadHarness,
    expected_loaded: *const loaded_diff.LoadedDiff,
    expected_token: review_selection_model.ReviewContentToken,
) !void {
    const primary = switch (app.reviewNavigationView().displayedReviewBody()) {
        .primary => |value| value,
        else => return error.ExpectedRetainedOrdinaryPrimary,
    };
    try std.testing.expect(primary.loaded == expected_loaded);
    const token = app.reviewNavigationView().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try std.testing.expect(token.eql(expected_token));
}

fn expectFreshCanonicalActionCapabilities(
    app: *ReadHarness,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    switch (app.reviewOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (app.reviewOperations().unstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.review.viewer.diff_scroll = 0;
    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.reviewOperations().selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedFreshHunkUnstageCapability,
    }

    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (app.reviewOperations().selectedHunkStageTarget(allocator)) {
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
    try std.testing.expectEqual(expected_source_revision, app.pages.review.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.review.status_snapshot_revision);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.status_load.isFresh());

    const request = app.pages.review.review_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(request.matchesBorrowed(
        app.pages.review.repository_read_authority.epoch,
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

    const published = app.reviewNavigationView().activeCombinedProjection() orelse
        return error.ExpectedFreshCombinedPublication;
    try std.testing.expect(published.displayFile().hunks.ptr != prior_hunks);
    try std.testing.expect(published.presentation.content_token.eql(
        diff_presentation_identity.ContentToken.init(expected_source_revision),
    ));
    try std.testing.expectEqual(
        expected_status_revision,
        published.authority.status_snapshot_revision,
    );

    const authority = app.reviewNavigationView().activeHunkAuthority() orelse
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
    try std.testing.expectEqual(expected_source_revision, app.pages.review.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.review.status_snapshot_revision);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.status_load.isFresh());

    const request = app.pages.review.review_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(request.matchesBorrowed(
        app.pages.review.repository_read_authority.epoch,
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
    try std.testing.expect(app.reviewNavigationView().displayedReviewBody() == .cached);
    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);

    switch (app.reviewOperations().stageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileStageCapability,
    }
    switch (app.reviewOperations().unstageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFreshFileUnstageCapability,
    }

    app.pages.review.viewer.diff_scroll = 0;
    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(
            ToggleStageOperation.unstage,
            operation,
        ),
        else => return error.ExpectedFreshHunkUnstageOperation,
    }
    switch (app.reviewOperations().selectedHunkStageTarget(allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedHunk,
    }
    switch (app.reviewOperations().selectedHunkUnstageTarget(allocator)) {
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
        expected: app_review_projection.Kind,
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
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

        try finishCanonicalPublicationAction(
            &app,
            &ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);
        try finishCanonicalPublicationStatus(
            &app,
            &ctx,
            allocator,
            roots.a,
            reads,
            case.status,
        );
        switch (case.source) {
            .loaded => try finishCanonicalPublicationSource(
                &app,
                &ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            ),
            .empty => try finishCanonicalPublicationEmpty(&app, &ctx, reads),
            .unchanged => try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
                .identity = reads.source_identity,
                .read_epoch = reads.source_read_epoch,
                .generation = reads.source_generation,
                .background_cycle_id = reads.source_cycle_id,
                .result = .{
                    .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
                },
            }),
        }

        try app.reviewRead().ensureProjection(&ctx);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
        defer request.deinit(allocator);
        try std.testing.expectEqual(case.expected, request.kind);
        try std.testing.expectEqualStrings("a", request.path_key);
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);
    }
}

fn expectOrdinaryPrimaryNoTargetPublication(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    source_changes: bool,
) !void {
    var app = try ordinaryPrimaryPublicationTestApp(allocator, repo_root);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    app.reviewNavigation().enterSearchMode();
    setDiffSearchInput(&app, "new");
    app.reviewNavigation().submitSearch();
    const search_before = app.pages.review.search.match orelse
        return error.ExpectedSearchMatch;
    const search_offset_before = app.pages.review.search.match_offset;
    const primary_before = switch (app.reviewNavigationView().displayedReviewBody()) {
        .primary => |value| value,
        else => return error.ExpectedOrdinaryPrimary,
    };
    const owner_before = primary_before.loaded;
    const source_text_before = primary_before.loaded.text.ptr;
    const tree_nodes_before = primary_before.loaded.tree.nodes.ptr;
    const status_root_before = app.pages.review.git_status.repo_root.?.ptr;
    const status_entries_before = app.pages.review.git_status.document.entries.ptr;
    const token_before = try installCanonicalPublicationLineageOwners(
        &app,
        allocator,
        repo_root,
    );
    const source_revision_before = app.pages.review.source_session_revision;
    const status_revision_before = app.pages.review.status_snapshot_revision;
    const cursor_before = app.pages.review.viewer.diff_cursor;
    const scroll_before = app.pages.review.viewer.diff_scroll;
    const horizontal_before = app.pages.review.viewer.diff_horizontal_scroll;
    const sidebar_horizontal_before =
        app.pages.review.viewer.sidebar_horizontal_scroll;

    try finishCanonicalPublicationAction(
        &app,
        &ctx,
        allocator,
        .stage_file,
        repo_root,
    );
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationStatus(
        &app,
        &ctx,
        allocator,
        repo_root,
        reads,
        " M a\x00",
    );
    try expectRetainedOrdinaryPrimaryPublication(&app, owner_before, token_before);
    try std.testing.expect(
        app.pages.review.git_status.repo_root.?.ptr == status_root_before,
    );
    try std.testing.expect(
        app.pages.review.git_status.document.entries.ptr == status_entries_before,
    );
    try std.testing.expectEqual(
        source_revision_before,
        app.pages.review.source_session_revision,
    );
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.review.status_snapshot_revision,
    );
    try std.testing.expect(!app.pages.review.status_load.isFresh());
    try std.testing.expectEqual(
        context.SelectedTarget{ .diff_file = 0 },
        app.pages.review.viewer.selected_target.?,
    );
    try std.testing.expectEqual(cursor_before, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(
        horizontal_before,
        app.pages.review.viewer.diff_horizontal_scroll,
    );
    try std.testing.expectEqual(
        sidebar_horizontal_before,
        app.pages.review.viewer.sidebar_horizontal_scroll,
    );
    try std.testing.expectEqual(
        search_before.coordinate,
        app.pages.review.search.match.?.coordinate,
    );
    try std.testing.expectEqual(
        search_offset_before,
        app.pages.review.search.match_offset,
    );
    const retained_selection = app.pages.review.completed_selection orelse
        return error.ExpectedRetainedCompletedSelection;
    try std.testing.expect(retained_selection.token.eql(token_before));
    try std.testing.expect(app.pages.review.staged_hunks.containsExact(
        repo_root,
        "a",
        .{ .content = token_before, .display_hunk_index = 1 },
    ));
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(review_read.testing.readBusy(app.reviewRead()));
    try std.testing.expect(app.reviewOperations().stageTarget() == .stale_source);

    if (source_changes) {
        try finishCanonicalPublicationSource(
            &app,
            &ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
    } else {
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = reads.source_identity,
            .read_epoch = reads.source_read_epoch,
            .generation = reads.source_generation,
            .background_cycle_id = reads.source_cycle_id,
            .result = .{
                .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
            },
        });
    }

    try app.reviewRead().ensureProjection(&ctx);
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 0), entries.len);
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, repo_root, reads);

    try std.testing.expect(app.pages.review.review_projection.displayed == .idle);
    try std.testing.expect(app.pages.review.review_projection.pending == null);
    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expect(app.pages.review.canonical_publication == null);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
    try std.testing.expect(app.pages.review.status_load.isFresh());
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.review.status_snapshot_revision,
    );
    try std.testing.expect(
        app.pages.review.git_status.repo_root.?.ptr == status_root_before,
    );
    try std.testing.expect(
        app.pages.review.git_status.document.entries.ptr == status_entries_before,
    );
    try std.testing.expectEqualStrings(
        "a",
        app.reviewNavigationView().selectedStagePathKey().?,
    );
    try std.testing.expectEqual(
        context.SelectedTarget{ .diff_file = 0 },
        app.pages.review.viewer.selected_target.?,
    );
    try std.testing.expect(app.reviewReloadView().projectionTarget() == null);
    try std.testing.expectEqualStrings("new", app.pages.review.search.query.slice());
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
    switch (app.reviewOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings(repo_root, target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
        },
        else => return error.ExpectedFreshFileStageCapability,
    }

    const primary_after = switch (app.reviewNavigationView().displayedReviewBody()) {
        .primary => |value| value,
        else => return error.ExpectedFinalOrdinaryPrimary,
    };
    const token_after = app.reviewNavigationView().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
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
            app.pages.review.source_session_revision,
        );
        try std.testing.expect(!token_after.eql(token_before));
        try std.testing.expect(app.pages.review.completed_selection == null);
        try std.testing.expect(!app.pages.review.staged_hunks.containsExact(
            repo_root,
            "a",
            .{ .content = token_before, .display_hunk_index = 1 },
        ));
        try std.testing.expect(app.pages.review.search.match != null);
        try std.testing.expect(
            app.pages.review.viewer.diff_scroll <
                app.reviewNavigationView().displayedDiffLineCount(),
        );
        try std.testing.expect(
            app.pages.review.viewer.diff_horizontal_scroll <= horizontal_before,
        );
    } else {
        try std.testing.expect(primary_after.loaded == owner_before);
        try std.testing.expect(primary_after.loaded.tree.nodes.ptr == tree_nodes_before);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.review.source_session_revision,
        );
        try std.testing.expect(token_after.eql(token_before));
        const completed = app.pages.review.completed_selection orelse
            return error.ExpectedRetainedCompletedSelection;
        try std.testing.expect(completed.token.eql(token_before));
        try std.testing.expect(app.pages.review.staged_hunks.containsExact(
            repo_root,
            "a",
            .{ .content = token_before, .display_hunk_index = 1 },
        ));
        try std.testing.expectEqual(cursor_before, app.pages.review.viewer.diff_cursor);
        try std.testing.expectEqual(scroll_before, app.pages.review.viewer.diff_scroll);
        try std.testing.expectEqual(
            horizontal_before,
            app.pages.review.viewer.diff_horizontal_scroll,
        );
        try std.testing.expectEqual(
            sidebar_horizontal_before,
            app.pages.review.viewer.sidebar_horizontal_scroll,
        );
        try std.testing.expectEqual(
            search_before.coordinate,
            app.pages.review.search.match.?.coordinate,
        );
        try std.testing.expectEqual(
            search_offset_before,
            app.pages.review.search.match_offset,
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
    @memcpy(app.pages.review.search.query.buffer[0..query.len], query);
    app.pages.review.search.query.len = query.len;
    app.pages.review.search.query.cursor = query.len;
    setDiffSearchInput(app, query);
}

fn setDiffSearchInput(app: *ReadHarness, query: []const u8) void {
    @memcpy(app.pages.review.search.input.buffer[0..query.len], query);
    app.pages.review.search.input.len = query.len;
    app.pages.review.search.input.cursor = query.len;
}

fn acceptTestSource(app: *ReadHarness) void {
    app.pages.review.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn testSessionHunkMarkKey(source_session_revision: u64, display_hunk_index: usize) git_ops.SessionHunkMarkKey {
    return .{
        .content = .{
            .repo_epoch = 0,
            .root_identity = null,
            .source = review_selection_model.SourceBasis.init(.unstaged),
            .source_session_revision = source_session_revision,
            .display = .{ .loaded = .init("test diff") },
        },
        .display_hunk_index = display_hunk_index,
    };
}

fn currentTestSessionHunkMarkKey(app: *const ReadHarness, display_hunk_index: usize) !git_ops.SessionHunkMarkKey {
    return .{
        .content = app.reviewNavigationView().currentContentToken() orelse return error.ExpectedReviewContentToken,
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
    try app.pages.review.staged_hunks.addExact(
        allocator,
        repo_root,
        path,
        try currentTestSessionHunkMarkKey(app, display_hunk_index),
    );
}

fn syncTestActivation(app: *ReadHarness) void {
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

fn clearPendingStatusTasks(ctx: *chasen.Ctx(ReadHarness.Msg), allocator: std.mem.Allocator) void {
    // finishStageHunk queues a status refresh. These tests assert the ReadHarness-side
    // state transition only, so clean up the queued task context explicitly.
    for (ctx.takePendingTasksWith()) |entry| {
        const task: *StatusLoadTask = @ptrCast(@alignCast(entry.ctx));
        StatusLoadTask.destroy(task, allocator);
    }
}

fn clearPendingRepositoryTasks(ctx: *chasen.Ctx(ReadHarness.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn clearPendingStatusAndDiffTasks(ctx: *chasen.Ctx(ReadHarness.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn testCombinedHunkBundle(allocator: std.mem.Allocator) !app_review_projection.CombinedHunkBundle {
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
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
    };
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    _ = app.pageCoordinator().activateReview();
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
    app.pages.review.activation.deactivate();
    _ = app.pageCoordinator().activateReview();
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
        .pages = .{ .review = .{
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
        app.pages.review.deinit(allocator);
        app.repo_session.repo_state.deinit(allocator);
    }
    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
    defer status.deinit();
    try app.pages.review.git_status.replace(repo_root, &status);
    acceptTestSource(&app);
    return app;
}

test "Review revalidation startup retains intent through two queue rejections and scheduler acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    const epoch_before_launch = app.pages.review.repository_read_authority.epoch;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    const epoch_advanced =
        app.pages.review.repository_read_authority.epoch.eql(epoch_before_launch.next());
    const generation_before_terminal = app.pages.review.load.generation;

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 16,
    };
    defer ctx.runtimeClearPendingEffectCopies();
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;
    const generation_after_rejections = app.pages.review.load.generation;
    ctx._pending_tasks_with_len = 0;
    defer clearPendingRepositoryTasks(&ctx, allocator);

    try runReadCoordinationTail(&app, &ctx);
    const accepted = ctx.takePendingTasksWith();
    const accepted_count = accepted.len;
    const generation_after_acceptance = app.pages.review.load.generation;
    var completions: [3]ReadHarness.Msg = undefined;
    if (accepted.len == completions.len) {
        for (accepted, 0..) |entry, index| {
            completions[index] = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        }
        for (&completions) |*completion| {
            try finishOwnedReviewRead(&app, &ctx, completion.*);
            completion.* = undefined;
        }
    } else {
        for (accepted) |entry| {
            var completion = entry.failed(entry.ctx, .runtime_abandoned, allocator);
            completion.deinitUndelivered(allocator);
        }
    }
    const duplicate_count_after_terminal = ctx._pending_tasks_with_len;

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
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
}

test "Review revalidation startup lets retained intent reach manual universal acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const generation_before_terminal = app.pages.review.load.generation;

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 16,
    };
    defer ctx.runtimeClearPendingEffectCopies();
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;
    const generation_after_same_update_rejections = app.pages.review.load.generation;

    // A neutral update under the same queue pressure must observe the retained
    // owner and make one more rejected scheduler attempt. An implementation
    // which pre-consumed the intent on either earlier rejection cannot satisfy
    // this generation transition merely because the later manual reload starts.
    try runReadCoordinationTail(&app, &ctx);
    const generation_after_later_rejection = app.pages.review.load.generation;

    ctx._pending_tasks_with_len = 0;
    defer clearPendingRepositoryTasks(&ctx, allocator);
    switch (app.reviewRead().prepareManualReload()) {
        .blocked => {},
        .ready => try app.reviewRead().startPreparedManualReload(&ctx),
    }
    try runReadCoordinationTail(&app, &ctx);
    const accepted = ctx.takePendingTasksWith();
    const accepted_count = accepted.len;
    const generation_after_manual_acceptance = app.pages.review.load.generation;
    var completions: [3]ReadHarness.Msg = undefined;
    if (accepted.len == completions.len) {
        for (accepted, 0..) |entry, index| {
            completions[index] = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        }
        for (&completions) |*completion| {
            try finishOwnedReviewRead(&app, &ctx, completion.*);
            completion.* = undefined;
        }
    } else {
        for (accepted) |entry| {
            var completion = entry.failed(entry.ctx, .runtime_abandoned, allocator);
            completion.deinitUndelivered(allocator);
        }
    }
    const duplicate_count_after_terminal = ctx._pending_tasks_with_len;

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
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
}

test "Review revalidation startup drains partial auxiliaries before one replacement" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, " M old.zig\x00");
    try app.pages.review.git_status.replace(roots.a, &old_status);
    var old_branch = try branchStatusBundleForTest(allocator, .{
        .oid = "old-oid",
        .branch = "old-branch",
    });
    try app.pages.review.branch_status.replace(roots.a, &old_branch);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    app.pages.review.activation.queueRevalidation();

    const saturated_slots: usize = 14;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = saturated_slots,
    };
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx,
        pending,
        roots.a,
        .stage_file,
    ) catch false;

    const accepted_tail_len = ctx._pending_tasks_with_len - saturated_slots;
    var status_message: ?ReadHarness.Msg = null;
    var branch_message: ?ReadHarness.Msg = null;
    if (accepted_tail_len == 2) {
        const status_task: *StatusLoadTask =
            @ptrCast(@alignCast(ctx._pending_tasks_with[saturated_slots].ctx));
        var changed_status =
            try git_status.StatusBundle.parseOwned(allocator, " M new.zig\x00");
        status_message = ReadHarness.Msg.loadFinished(.{ .review = .{ .status = .{
            .identity = status_task.identity,
            .read_epoch = status_task.read_epoch,
            .generation = status_task.generation,
            .background_cycle_id = status_task.background_cycle_id,
            .repo_root = status_task.repo_root,
            .result = .{ .loaded = changed_status },
        } } });
        status_task.repo_root = &.{};
        status_task.environment.deinit();
        status_task.root.deinit();
        allocator.destroy(status_task);
        changed_status = undefined;

        const branch_task: *BranchStatusLoadTask =
            @ptrCast(@alignCast(ctx._pending_tasks_with[saturated_slots + 1].ctx));
        var changed_branch = try branchStatusBundleForTest(allocator, .{
            .oid = "new-oid",
            .branch = "new-branch",
        });
        branch_message = ReadHarness.Msg.loadFinished(.{ .review = .{ .branch_status = .{
            .identity = branch_task.identity,
            .read_epoch = branch_task.read_epoch,
            .generation = branch_task.generation,
            .background_cycle_id = branch_task.background_cycle_id,
            .repo_root = branch_task.repo_root,
            .result = .{ .loaded = changed_branch },
        } } });
        branch_task.repo_root = &.{};
        BranchStatusLoadTask.destroy(branch_task, allocator);
        changed_branch = undefined;
    } else {
        for (ctx._pending_tasks_with[saturated_slots..ctx._pending_tasks_with_len]) |entry| {
            var completion = entry.failed(entry.ctx, .runtime_abandoned, allocator);
            completion.deinitUndelivered(allocator);
        }
    }
    ctx._pending_tasks_with_len = 0;
    defer clearPendingRepositoryTasks(&ctx, allocator);

    if (status_message) |message| try finishOwnedReviewRead(&app, &ctx, message);
    const replacement_before_branch = ctx._pending_tasks_with_len;
    if (branch_message) |message| try finishOwnedReviewRead(&app, &ctx, message);
    const replacement_count = ctx._pending_tasks_with_len;
    const status_retained =
        app.pages.review.git_status.document.entries.len == 1 and
        std.mem.eql(
            u8,
            app.pages.review.git_status.document.entries[0].path,
            "old.zig",
        );
    const branch_retained =
        app.pages.review.branch_status.status.branchName() != null and
        std.mem.eql(
            u8,
            app.pages.review.branch_status.status.branchName().?,
            "old-branch",
        );

    try std.testing.expect(fence_closed);
    try std.testing.expect(terminal_returned_normally);
    try std.testing.expectEqual(@as(usize, 2), accepted_tail_len);
    try std.testing.expectEqual(@as(u8, 0), replacement_before_branch);
    try std.testing.expectEqual(@as(u8, 3), replacement_count);
    try std.testing.expect(status_retained);
    try std.testing.expect(branch_retained);
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
}

test "Review revalidation startup detaches mismatched runtime failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    try replaceMutationFenceTestRepo(&app, allocator, roots.b);

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try std.testing.expect(try finishTestAction(&app, &ctx, pending, roots.a, null));

    try std.testing.expect(fence_closed);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings(roots.b, app.repoSessionView().activeRoot().?);
}

test "Review revalidation startup preserves only ordinary intent after mismatch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    try replaceMutationFenceTestRepo(&app, allocator, roots.b);
    app.pages.review.activation.queueRevalidation();

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try std.testing.expect(try finishTestAction(&app, &ctx, pending, roots.a, null));

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    const current_source_root = if (entries.len == 3) blk: {
        const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
        break :blk source_task.request.repo_root;
    } else null;

    try std.testing.expect(fence_closed);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(current_source_root != null);
    try std.testing.expectEqualStrings(roots.b, current_source_root.?);
}

test "Review revalidation startup retries repository discovery after detached terminal" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("gIt_retry_selector", "redirect");
    try parent_environment.put("GITFRAME_S1_CANARY", "preserved");
    var app = try mutationFenceRepoTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.env_map = &parent_environment;

    const pending = app.actionLifecycle().prepare(.stage_file).pending;
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state = .{};
    app.repo_session.repo_epoch +%= 1;
    app.pages.review.activation.deactivate();
    _ = app.pageCoordinator().activateReview();
    app.pages.review.activation.queueRevalidation();

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 16,
    };
    defer ctx.runtimeClearPendingEffectCopies();
    const terminal_returned_normally = finishTestAction(
        &app,
        &ctx,
        pending,
        roots.a,
        null,
    ) catch false;
    ctx._pending_tasks_with_len = 0;
    defer clearPendingRepositoryTasks(&ctx, allocator);

    try runReadCoordinationTail(&app, &ctx);
    const retry_count = ctx._pending_tasks_with_len;
    const retry_task: *RepoDiscoveryTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));

    try std.testing.expect(fence_closed);
    try std.testing.expect(terminal_returned_normally);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 1), retry_count);
    try std.testing.expectEqualStrings(
        "preserved",
        retry_task.environment.borrow().get("GITFRAME_S1_CANARY").?,
    );
    try std.testing.expect(retry_task.environment.borrow().get("gIt_retry_selector") == null);
}

test "Review revalidation startup discards inactive and one-shot terminal fallback" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var inactive = try mutationFenceRepoTestApp(allocator, roots.a);
    defer inactive.pages.review.deinit(allocator);
    defer inactive.repo_session.repo_state.deinit(allocator);
    const inactive_pending = inactive.actionLifecycle().prepare(.stage_file).pending;
    inactive.acceptActionLaunch(inactive_pending);
    const inactive_fence_closed =
        !inactive.pages.review.repository_read_authority.mayStartRepositoryRead();
    inactive.pages.review.activation.deactivate();
    inactive.active_page = .repository;
    var inactive_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try std.testing.expect(try finishTestAction(
        &inactive,
        &inactive_ctx,
        inactive_pending,
        roots.a,
        null,
    ));

    var one_shot = try mutationFenceRepoTestApp(allocator, roots.a);
    defer one_shot.pages.review.deinit(allocator);
    defer one_shot.repo_session.repo_state.deinit(allocator);
    one_shot.config.source = .stdin;
    one_shot.pages.review.activation.deactivate();
    _ = one_shot.pageCoordinator().activateReview();
    const one_shot_pending = one_shot.actionLifecycle().prepare(.stage_file).pending;
    one_shot.acceptActionLaunch(one_shot_pending);
    const one_shot_fence_closed =
        !one_shot.pages.review.repository_read_authority.mayStartRepositoryRead();
    var one_shot_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try std.testing.expect(try finishTestAction(
        &one_shot,
        &one_shot_ctx,
        one_shot_pending,
        roots.a,
        null,
    ));

    try std.testing.expect(inactive_fence_closed);
    try std.testing.expect(!inactive.action_runtime.view().hasPending());
    try std.testing.expect(inactive.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 0), inactive_ctx._pending_tasks_with_len);
    try std.testing.expect(one_shot_fence_closed);
    try std.testing.expect(!one_shot.action_runtime.view().hasPending());
    try std.testing.expect(one_shot.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 0), one_shot_ctx._pending_tasks_with_len);
}

test "Review revalidation startup retains both intents after status-only rejection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    // Terminal-only fallback: rejecting the narrow status member must leave
    // enough authority for a later neutral scheduler opportunity to start the
    // full replacement.
    {
        var app = try initStageHunkLaunchApp(allocator, roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.review.deinit(allocator);

        const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
        try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
        app.acceptActionLaunch(pending);
        const fence_closed =
            !app.pages.review.repository_read_authority.mayStartRepositoryRead();

        var ctx: chasen.Ctx(ReadHarness.Msg) = .{
            ._allocator = allocator,
            ._pending_tasks_with_len = 16,
        };
        defer ctx.runtimeClearPendingEffectCopies();
        const terminal_returned_normally = finishTestAction(
            &app,
            &ctx,
            pending,
            roots.a,
            .{ .stage_hunk = .{
                .repo_root = roots.a,
                .path = "a",
                .hunk_index = 0,
                .session_mark_mutation = .none,
            } },
        ) catch false;
        ctx._pending_tasks_with_len = 0;
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try runReadCoordinationTail(&app, &ctx);
        const later_full_count = ctx._pending_tasks_with_len;

        try std.testing.expect(fence_closed);
        try std.testing.expect(terminal_returned_normally);
        try std.testing.expectEqual(@as(u8, 3), later_full_count);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    }

    // Ordinary + terminal: the existing ordinary scalar is direct evidence
    // that status rejection consumed neither class. The terminal-only case
    // above supplies the independent evidence for the second scalar.
    {
        var app = try initStageHunkLaunchApp(allocator, roots.a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.pages.review.deinit(allocator);

        const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
        try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
        app.acceptActionLaunch(pending);
        app.pages.review.activation.queueRevalidation();
        const activation_id = app.pages.review.activation.next_activation_id;

        var ctx: chasen.Ctx(ReadHarness.Msg) = .{
            ._allocator = allocator,
            ._pending_tasks_with_len = 16,
        };
        defer ctx.runtimeClearPendingEffectCopies();
        const terminal_returned_normally = finishTestAction(
            &app,
            &ctx,
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
            app.pages.review.activation.revalidation_requested == activation_id;
        ctx._pending_tasks_with_len = 0;
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try runReadCoordinationTail(&app, &ctx);
        const later_full_count = ctx._pending_tasks_with_len;

        try std.testing.expect(terminal_returned_normally);
        try std.testing.expect(ordinary_retained);
        try std.testing.expectEqual(@as(u8, 3), later_full_count);
        try std.testing.expect(!app.action_runtime.view().hasPending());
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    }
}

test "Review revalidation startup keeps ordinary full intent after status-only acceptance" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);

    const pending = app.actionLifecycle().prepare(.stage_hunk).pending;
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    app.acceptActionLaunch(pending);
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    app.pages.review.activation.queueRevalidation();

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try std.testing.expect(try finishTestAction(
        &app,
        &ctx,
        pending,
        roots.a,
        .{ .stage_hunk = .{
            .repo_root = roots.a,
            .path = "a",
            .hunk_index = 0,
            .session_mark_mutation = .none,
        } },
    ));
    const status_entries = ctx.takePendingTasksWith();
    const status_only_count = status_entries.len;
    var status_terminal: ?ReadHarness.Msg = null;
    if (status_entries.len == 1) {
        status_terminal = status_entries[0].failed(
            status_entries[0].ctx,
            .runtime_abandoned,
            allocator,
        );
    } else {
        for (status_entries) |entry| {
            var completion = entry.failed(entry.ctx, .runtime_abandoned, allocator);
            completion.deinitUndelivered(allocator);
        }
    }
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    if (status_terminal) |message| try finishOwnedReviewRead(&app, &ctx, message);
    const full_count_after_status_terminal = ctx._pending_tasks_with_len;

    try std.testing.expect(fence_closed);
    try std.testing.expectEqual(@as(usize, 1), status_only_count);
    try std.testing.expectEqual(@as(u8, 3), full_count_after_status_terminal);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
}

test "status-only hunk refresh ignores stale completion and closes on exact runtime failure" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .allocator = allocator,
        .pages = .{ .review = .{
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
    };
    defer app.pages.review.deinit(allocator);
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, 1),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "stale failure" },
    });
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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
    _ = status_app.pageCoordinator().activateReview();
    var status_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    try std.testing.expectError(
        error.TaskLimitExceeded,
        review_read.testing.startStatusLoadTracked(status_app.reviewRead(), &status_ctx, roots.a, .foreground, null, null),
    );
    status_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(status_app.pages.review.status_load.pending == null);
    try std.testing.expectEqualStrings("could not start status load task", status_app.pages.review.status.text());

    var branch_app: ReadHarness = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    branch_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer branch_app.repo_session.repo_state.deinit(allocator);
    _ = branch_app.pageCoordinator().activateReview();
    var branch_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    _ = review_read.testing.startBranchStatusLoad(branch_app.reviewRead(), &branch_ctx, roots.a, null);
    branch_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(branch_app.pages.review.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not start branch status load task", branch_app.pages.review.status.text());

    var projection_app: ReadHarness = .{
        .allocator = allocator,
        .pages = .{ .review = .{
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
    _ = projection_app.pageCoordinator().activateReview();
    defer projection_app.reviewReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.review.git_status.deinit();
    var staged = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try projection_app.pages.review.git_status.replace(roots.a, &staged);
    var projection_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    try std.testing.expectError(error.TaskLimitExceeded, projection_app.reviewRead().ensureProjection(&projection_ctx));
    projection_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(projection_app.pages.review.review_projection.pending == null);
}

test "action refresh closes source rejection after its already-started status member finishes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .allocator = allocator,
        .config = .{ .source = .stdin },
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);

    // Leave exactly one task slot. Status takes it first; branch and source
    // spawn are then rejected. The action owner must retain the exact status
    // generation and close only when that already-started member terminates.
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 15,
    };
    try std.testing.expectError(error.TaskLimitExceeded, review_read.testing.startDiffLoadWithRepoRoot(
        app.reviewRead(),
        &ctx,
        roots.a,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 9,
        },
    ));
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(review_page.action_cursor.Terminal.rejected_spawn, basis.memberState(.source).?.terminal);
    try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);

    const status_entry = ctx._pending_tasks_with[15];
    ctx._pending_tasks_with_len = 0;
    const status_failure = status_entry.failed(status_entry.ctx, .runtime_abandoned, allocator);
    try finishOwnedReviewRead(&app, &ctx, status_failure);

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(app.pages.review.status_load.pending == null);
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
    defer source_app.pages.review.deinit(backing);
    _ = source_app.pageCoordinator().activateReview();
    try installTestActionCursor(&source_app, backing, .file, "source.txt", 9);
    try promoteTestActionCursor(&source_app, 9);
    var source_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = source_failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, review_read.testing.startDiffLoadWithRepoRoot(
        source_app.reviewRead(),
        &source_ctx,
        null,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 9,
        },
    ));
    try std.testing.expect(source_app.pages.review.load.pending == null);
    try std.testing.expect(source_app.pages.review.pending_reload == null);
    try std.testing.expect(source_app.pages.review.canonical_publication == null);
    try std.testing.expect(!source_app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), source_ctx.takePendingTasksWith().len);

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
    defer status_app.pages.review.deinit(backing);
    _ = status_app.pageCoordinator().activateReview();
    try installTestActionCursor(&status_app, backing, .file, "status.txt", 10);
    try promoteTestActionCursor(&status_app, 10);
    var status_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = status_failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, review_read.testing.startDiffLoadWithRepoRoot(
        status_app.reviewRead(),
        &status_ctx,
        roots.a,
        .{
            .clear_visible_state = false,
            .kind = .action_result,
            .action_cursor_generation = 10,
        },
    ));
    try std.testing.expect(status_app.pages.review.load.pending == null);
    try std.testing.expect(status_app.pages.review.pending_reload == null);
    try std.testing.expect(status_app.pages.review.canonical_publication == null);
    try std.testing.expect(status_app.pages.review.status_load.pending == null);
    try std.testing.expect(!status_app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), status_ctx.takePendingTasksWith().len);

    var branch_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    var branch_app: ReadHarness = .{
        .allocator = branch_failing.allocator(),
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(backing, roots.a) } },
    };
    branch_app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer branch_app.repo_session.repo_state.deinit(backing);
    _ = branch_app.pageCoordinator().activateReview();
    var branch_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = branch_failing.allocator() };
    _ = review_read.testing.startBranchStatusLoad(branch_app.reviewRead(), &branch_ctx, roots.a, null);
    try std.testing.expect(branch_app.pages.review.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not allocate branch status load task", branch_app.pages.review.status.text());

    var projection_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 4 });
    var projection_app: ReadHarness = .{
        .allocator = projection_failing.allocator(),
        .pages = .{ .review = .{
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
    _ = projection_app.pageCoordinator().activateReview();
    defer projection_app.reviewReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.review.git_status.deinit();
    var mixed = try git_status.StatusBundle.parseOwned(backing, "MM a\x00");
    try projection_app.pages.review.git_status.replace(roots.a, &mixed);
    var projection_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = projection_failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, projection_app.reviewRead().ensureProjection(&projection_ctx));
    try std.testing.expect(projection_app.pages.review.review_projection.pending == null);
}

test "stale branch status result is ignored" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .branch_status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.pages.review.branch_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .branch = "stale",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });

    app.reviewRead().finishBranchStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.branch_status.repo_root == null);
    try std.testing.expect(std.meta.eql(git_branch_status.Head.unknown, app.pages.review.branch_status.status.head));
    try std.testing.expectEqual(@as(?u64, 2), if (app.pages.review.branch_status_load.pending) |pending| pending.generation else null);
}

test "Review page header identical branch recovery redraws fresh terminal" {
    var app: ReadHarness = .{ .allocator = std.testing.allocator };
    defer app.pages.review.branch_status.deinit();
    var current = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &current);
    const root_ptr = app.pages.review.branch_status.repo_root.?.ptr;

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .branch));
    const generation = app.pages.review.branch_status_load.prepare(true);
    app.pages.review.branch_status_load.begin(cycle_id, .{});
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.reviewRead().finishBranchStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient branch failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.review.branch_status.repo_root.?);
    try std.testing.expect(!app.pages.review.branch_status_load.isFresh());
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.review.branch_status_load.prepare(true);
    app.pages.review.branch_status_load.begin(null, .{});
    app.redraw_plan = .{};
    const same = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    app.reviewRead().finishBranchStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.review.branch_status_load.isFresh());
    try std.testing.expectEqual(root_ptr, app.pages.review.branch_status.repo_root.?.ptr);
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
        .active_page = .review,
        .config = .{ .source = .unstaged },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, root_path);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    app.pages.review.load = app_test_support.loadState(app_test_support.loadedDiffOne());
    app.pages.review.viewer.selected_target = .{ .status_only = 0 };
    _ = app.pages.review.activation.activate(0, .pending, .pending, .pending);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? new.zig\x00");
    try app.pages.review.git_status.replace(root_path, &status_bundle);
    app.pages.review.review_projection.installReady(.{
        .request = try app_review_projection.testing.cloneRequestWithRootIdentity(
            allocator,
            app.pages.review.activation.currentIdentity().?,
            11,
            root_path,
            "new.zig",
            .generated_added_file,
            .unstaged,
            0,
            0,
            app.repo_session.repo_state.root.?.identity,
        ),
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(
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
    var prepare_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = prepare_failing.allocator(), ._io = io };
    try app.reviewRead().ensureProjection(&prepare_ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), prepare_ctx.takePendingTasksWith().len);
    try expectGeneratedProjectionEligible(&app);

    // Four string allocations build the page/task request clones. Fail the
    // following task-object allocation and verify both clones are reclaimed.
    var task_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 4 });
    app.allocator = task_failing.allocator();
    var allocation_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = task_failing.allocator(), ._io = io };
    try app.reviewRead().ensureProjection(&allocation_ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);
    try expectGeneratedProjectionEligible(&app);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) ReadHarness.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) ReadHarness.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    try app.reviewRead().ensureProjection(&spawn_ctx);
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);
    try expectGeneratedProjectionEligible(&app);

    var retry_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.reviewRead().ensureProjection(&retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expect(app.pages.review.review_projection.hasSyntaxPending());
    try expectGeneratedProjectionEligible(&app);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "combined projection target is requested for mixed modified unstaged files" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.pages.review.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedCombinedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.combined_hunks, target.kind);
    try std.testing.expectEqual(app_review_projection.SourceKind.unstaged, target.source_kind);
    try std.testing.expectEqualStrings("/repo", target.repo_root);
    try std.testing.expectEqualStrings("a", target.path_key);

    app.config.source = .cached;
    try std.testing.expect(app.reviewReloadView().projectionTarget() == null);
}

test "Review ordinary primary publication retains primary until cached result" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]bool{ false, true }) |status_first| {
        var app = try ordinaryPrimaryPublicationTestApp(allocator, roots.a);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

        app.reviewNavigation().enterSearchMode();
        setDiffSearchInput(&app, "new");
        app.reviewNavigation().submitSearch();
        try std.testing.expect(app.pages.review.search.match != null);
        const primary = switch (app.reviewNavigationView().displayedReviewBody()) {
            .primary => |value| value,
            else => return error.ExpectedOrdinaryPrimary,
        };
        const primary_owner = primary.loaded;
        const primary_token = try installCanonicalPublicationLineageOwners(
            &app,
            allocator,
            roots.a,
        );
        const source_revision_before = app.pages.review.source_session_revision;
        const status_revision_before = app.pages.review.status_snapshot_revision;
        const horizontal_before = app.pages.review.viewer.diff_horizontal_scroll;

        try finishCanonicalPublicationAction(
            &app,
            &ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);

        if (status_first) {
            try finishCanonicalPublicationStatus(
                &app,
                &ctx,
                allocator,
                roots.a,
                reads,
                "M  a\x00",
            );
        } else {
            try finishCanonicalPublicationEmpty(&app, &ctx, reads);
        }
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);

        if (status_first) {
            try finishCanonicalPublicationEmpty(&app, &ctx, reads);
        } else {
            try finishCanonicalPublicationStatus(
                &app,
                &ctx,
                allocator,
                roots.a,
                reads,
                "M  a\x00",
            );
        }
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);

        try app.reviewRead().ensureProjection(&ctx);
        try expectRetainedOrdinaryPrimaryPublication(&app, primary_owner, primary_token);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
        var request_owned = true;
        defer if (request_owned) request.deinit(allocator);
        try std.testing.expectEqual(app_review_projection.Kind.cached_diff, request.kind);
        try std.testing.expectEqualStrings("a", request.path_key);
        try std.testing.expect(request.expected_presentation == null);
        request_owned = false;
        try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
            .request = request,
            .result = .{ .ready = .{
                .cached_diff = try app_load.buildLoadedBundle(
                    allocator,
                    app_test_support.diff_cached_projection,
                ),
            } },
        });
        request = undefined;
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

        try std.testing.expect(app.reviewNavigationView().displayedReviewBody() == .cached);
        try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
        try std.testing.expectEqual(
            source_revision_before + 1,
            app.pages.review.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before + 1,
            app.pages.review.status_snapshot_revision,
        );
        try std.testing.expect(app.pages.review.status_load.isFresh());
        try std.testing.expectEqualStrings(
            "a",
            app.reviewNavigationView().selectedStagePathKey().?,
        );
        try std.testing.expectEqual(
            context.SelectedTarget{ .status_only = 0 },
            app.pages.review.viewer.selected_target.?,
        );
        try std.testing.expectEqualStrings("new", app.pages.review.search.query.slice());
        try std.testing.expect(app.pages.review.search.match != null);
        try std.testing.expect(
            app.pages.review.viewer.diff_scroll <
                app.reviewNavigationView().displayedDiffLineCount(),
        );
        try std.testing.expect(
            app.pages.review.viewer.diff_horizontal_scroll <= horizontal_before,
        );
        try std.testing.expect(app.pages.review.completed_selection == null);
        try std.testing.expect(!app.pages.review.staged_hunks.containsExact(
            roots.a,
            "a",
            .{ .content = primary_token, .display_hunk_index = 1 },
        ));
        const final_token = app.reviewNavigationView().currentContentToken() orelse
            return error.ExpectedFinalCachedContentToken;
        try std.testing.expect(!final_token.eql(primary_token));
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));

        switch (app.reviewOperations().stageTarget()) {
            .already_staged => |path| try std.testing.expectEqualStrings("a", path),
            else => return error.ExpectedAlreadyStagedFile,
        }
        switch (app.reviewOperations().toggleStageTarget()) {
            .operation => |operation| try std.testing.expectEqual(
                ToggleStageOperation.unstage,
                operation,
            ),
            else => return error.ExpectedFileUnstageOperation,
        }
        switch (app.reviewOperations().unstageTarget()) {
            .ready => |target| {
                try std.testing.expectEqualStrings(roots.a, target.repo_root);
                try std.testing.expectEqualStrings("a", target.path);
            },
            else => return error.ExpectedFileUnstageCapability,
        }

        app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
        switch (app.reviewOperations().selectedHunkToggleOperation()) {
            .operation => |operation| try std.testing.expectEqual(
                ToggleStageOperation.unstage,
                operation,
            ),
            else => return error.ExpectedHunkUnstageOperation,
        }
        switch (app.reviewOperations().selectedHunkStageTarget(allocator)) {
            .already_staged_hunk => {},
            else => return error.ExpectedAlreadyStagedHunk,
        }
        switch (app.reviewOperations().selectedHunkUnstageTarget(allocator)) {
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

test "Review canonical publication exact acceptance retains navigation search and completed selection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationPrimaryTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.terminal_size.height = 12;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    app.reviewNavigation().enterSearchMode();
    setDiffSearchInput(&app, "staged");
    app.reviewNavigation().submitSearch();
    const search_before = app.pages.review.search.match orelse return error.ExpectedSearchMatch;
    const search_offset_before = app.pages.review.search.match_offset;
    app.pages.review.viewer.diff_horizontal_scroll = 2;
    const horizontal_before = app.pages.review.viewer.diff_horizontal_scroll;
    const sidebar_horizontal_before = app.pages.review.viewer.sidebar_horizontal_scroll;

    const displayed = app.reviewNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 1, .line_index = 0 },
        .focus = .{ .hunk_index = 1, .line_index = 0 },
        .moved = true,
    };
    app.pages.review.completed_selection = try review_selection_model.buildParsed(
        allocator,
        app.reviewNavigationView().currentContentToken() orelse return error.ExpectedReviewContentToken,
        displayed,
        selection,
    );
    const action_block = app.reviewNavigationView().selectionActionRenderBlock() orelse
        return error.ExpectedSelectionActionBlock;
    const summary_row = action_block.projection.actionPresentationRow(0) orelse
        return error.ExpectedSelectionActionSummary;
    app.pages.review.viewer.diff_scroll = summary_row;
    const selection_viewport_before = app.reviewNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedSelectionViewportAnchor;
    try std.testing.expectEqual(summary_row, selection_viewport_before.raw_presentation_scroll);
    try std.testing.expectEqual(@as(isize, 2), selection_viewport_before.signed_screen_delta);
    switch (selection_viewport_before.semantic_source) {
        .parsed => |coordinate| app.pages.review.viewer.diff_cursor = coordinate,
        .none, .generated_row => return error.ExpectedParsedSelectionViewportSource,
    }
    const cursor_before = app.pages.review.viewer.diff_cursor;
    const scroll_before = app.pages.review.viewer.diff_scroll;
    const token_before = app.pages.review.completed_selection.?.token;
    const clipboard_before = try app.pages.review.completed_selection.?.clipboardText(allocator);
    defer allocator.free(clipboard_before);
    const source_revision_before = app.pages.review.source_session_revision;
    const status_revision_before = app.pages.review.status_snapshot_revision;

    try finishCanonicalPublicationAction(&app, &ctx, allocator, .stage_file, roots.a);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationSource(
        &app,
        &ctx,
        allocator,
        reads,
        canonical_publication_combined_diff,
    );
    try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, "MM a\x00");
    try app.reviewRead().ensureProjection(&ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
    var candidate = try canonicalPublicationReuseCandidate(
        allocator,
        request.status_snapshot_revision,
    );
    const current = app.reviewNavigationView().displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    try std.testing.expect(diff_presentation_identity.exactEqual(current, candidate.displayFile()));
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    });
    candidate = undefined;
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

    try std.testing.expectEqual(cursor_before, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(sidebar_horizontal_before, app.pages.review.viewer.sidebar_horizontal_scroll);
    try std.testing.expectEqualStrings("staged", app.pages.review.search.query.slice());
    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expectEqual(search_before.coordinate, app.pages.review.search.match.?.coordinate);
    try std.testing.expectEqual(search_offset_before, app.pages.review.search.match_offset);
    const completed = app.pages.review.completed_selection orelse
        return error.ExpectedRetainedCompletedSelection;
    const selection_viewport_after = app.reviewNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedRetainedSelectionViewportAnchor;
    try std.testing.expect(selection_viewport_before.basis.eql(selection_viewport_after.basis));
    try std.testing.expectEqual(
        selection_viewport_before.raw_presentation_scroll,
        app.pages.review.viewer.diff_scroll,
    );
    const token_after = app.reviewNavigationView().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try std.testing.expect(!token_after.eql(token_before));
    try std.testing.expect(completed.token.eql(token_after));
    const clipboard_after = try completed.clipboardText(allocator);
    defer allocator.free(clipboard_after);
    try std.testing.expectEqualStrings(clipboard_before, clipboard_after);

    try std.testing.expectEqual(
        source_revision_before + 1,
        app.pages.review.source_session_revision,
    );
    try std.testing.expectEqual(
        status_revision_before,
        app.pages.review.status_snapshot_revision,
    );
    const published_request = app.pages.review.review_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(published_request.matchesBorrowed(
        app.pages.review.repository_read_authority.epoch,
        roots.a,
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    ));
    try std.testing.expect(published_request.matchesRootIdentity(app.repoSessionView().activeIdentity()));
    const expected_presentation = published_request.expected_presentation orelse
        return error.ExpectedPriorCanonicalPresentation;
    try std.testing.expect(expected_presentation.owner == .primary_loaded);
    try std.testing.expect(app.reviewNavigationView().activeCombinedProjection() == null);
    const authority = app.reviewNavigationView().activeHunkAuthority() orelse
        return error.ExpectedFreshHunkAuthority;
    try std.testing.expect(authority.authority == .combined);
    try std.testing.expectEqual(
        app.pages.review.status_snapshot_revision,
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

test "Review canonical publication exact reuse rebinds every retained lineage owner" {
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
            defer app.pages.review.deinit(allocator);
            defer app.repo_session.repo_state.deinit(allocator);
            var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

            const token_before = try installCanonicalPublicationLineageOwners(
                &app,
                allocator,
                roots.a,
            );
            const clipboard_before = try app.pages.review.completed_selection.?.clipboardText(
                allocator,
            );
            defer allocator.free(clipboard_before);
            const source_revision_before = app.pages.review.source_session_revision;

            try finishCanonicalPublicationAction(
                &app,
                &ctx,
                allocator,
                .stage_file,
                roots.a,
            );
            const reads = try takeCanonicalPublicationReads(&ctx, allocator);
            try finishCanonicalPublicationSource(
                &app,
                &ctx,
                allocator,
                reads,
                canonical_publication_combined_diff,
            );
            try finishCanonicalPublicationStatus(
                &app,
                &ctx,
                allocator,
                roots.a,
                reads,
                switch (kind) {
                    .combined => "MM a\x00",
                    .staged_only => "M  a\x00",
                },
            );
            try app.reviewRead().ensureProjection(&ctx);
            var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
            try std.testing.expectEqual(
                switch (kind) {
                    .combined => app_review_projection.Kind.combined_hunks,
                    .staged_only => app_review_projection.Kind.cached_diff,
                },
                request.kind,
            );
            const expected = request.expected_presentation orelse
                return error.ExpectedPriorCanonicalPresentation;
            try std.testing.expectEqual(
                switch (owner) {
                    .self_owned => app_review_projection.ExpectedPresentationOwner.combined_projection,
                    .primary_backed => app_review_projection.ExpectedPresentationOwner.primary_loaded,
                },
                expected.owner,
            );
            switch (kind) {
                .combined => {
                    var candidate = try canonicalPublicationReuseCandidate(
                        allocator,
                        request.status_snapshot_revision,
                    );
                    const current = app.reviewNavigationView().displayedDiffFile() orelse
                        return error.ExpectedDisplayedDiff;
                    try std.testing.expect(diff_presentation_identity.exactEqual(
                        current,
                        candidate.displayFile(),
                    ));
                    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
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
                    const current = app.reviewNavigationView().displayedDiffFile() orelse
                        return error.ExpectedDisplayedDiff;
                    try std.testing.expect(diff_presentation_identity.exactEqual(
                        current,
                        candidate.displayFile(),
                    ));
                    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
                        .request = request,
                        .result = .{ .staged_only_reuse_candidate = candidate },
                    });
                    candidate = undefined;
                },
            }
            request = undefined;
            try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

            try std.testing.expectEqual(
                source_revision_before + 1,
                app.pages.review.source_session_revision,
            );
            const token_after = app.reviewNavigationView().currentContentToken() orelse
                return error.ExpectedReviewContentToken;
            try std.testing.expect(!token_after.eql(token_before));
            const completed = app.pages.review.completed_selection orelse
                return error.ExpectedRetainedCompletedSelection;
            try std.testing.expect(completed.token.eql(token_after));
            const clipboard_after = try completed.clipboardText(allocator);
            defer allocator.free(clipboard_after);
            try std.testing.expectEqualStrings(clipboard_before, clipboard_after);
            try std.testing.expect(app.pages.review.staged_hunks.containsExact(
                roots.a,
                "a",
                .{ .content = token_after, .display_hunk_index = 1 },
            ));
            try std.testing.expect(!app.pages.review.staged_hunks.containsExact(
                roots.a,
                "a",
                .{ .content = token_before, .display_hunk_index = 1 },
            ));
        }
    }
}

test "Review canonical publication startup and status failure retain last good owners" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        const prior = app.reviewNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{
            ._allocator = allocator,
            ._pending_tasks_with_len = 16,
        };
        try finishCanonicalPublicationAction(&app, &ctx, allocator, .stage_file, roots.a);
        ctx._pending_tasks_with_len = 0;
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(app.pages.review.pending_reload == null);
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
    }

    for ([_]bool{ false, true }) |status_first| {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        const prior = app.reviewNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        try finishCanonicalPublicationAction(&app, &ctx, allocator, .stage_file, roots.a);
        const reads = try takeCanonicalPublicationReads(&ctx, allocator);

        if (!status_first) {
            try finishCanonicalPublicationSource(
                &app,
                &ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            );
        }
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
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
                &ctx,
                allocator,
                reads,
                app_test_support.diff_unstaged_projection,
            );
        }
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(app.pages.review.pending_reload == null);
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
    }

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        const prior = app.reviewNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        const source_revision_before = app.pages.review.source_session_revision;
        const status_revision_before = app.pages.review.status_snapshot_revision;

        const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
        try finishCanonicalPublicationSource(
            &app,
            &ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationStatusFailure(&app, &ctx, allocator, roots.a, reads);

        try std.testing.expect(app.pages.review.deferred_source_apply == null);
        const cycle = app.pages.review.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(cycle_id, cycle.id);
        try std.testing.expect(!cycle.pending.source);
        try std.testing.expect(!cycle.pending.status);
        try std.testing.expect(!cycle.pending.deferred_source_apply);
        try std.testing.expect(cycle.pending.branch);
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

        try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.review.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before,
            app.pages.review.status_snapshot_revision,
        );
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
    }

    {
        var app = try canonicalPublicationTestApp(allocator, roots.a);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        const prior = app.reviewNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const prior_hunks = prior.displayFile().hunks.ptr;
        const prior_content_token = prior.presentation.content_token;
        const source_revision_before = app.pages.review.source_session_revision;
        const status_revision_before = app.pages.review.status_snapshot_revision;
        const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const failed_cycle_id = reads.source_cycle_id orelse
            return error.ExpectedBackgroundCycle;
        try finishCanonicalPublicationSource(
            &app,
            &ctx,
            allocator,
            reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, failed_cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, "MM a\x00");
        try expectRetainedCanonicalPublication(&app, prior_hunks);

        ctx._pending_tasks_with_len = 16;
        try std.testing.expectError(error.TaskLimitExceeded, app.reviewRead().ensureProjection(&ctx));
        ctx._pending_tasks_with_len = 0;
        try std.testing.expect(app.pages.review.deferred_source_apply == null);
        const failed_cycle = app.pages.review.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(failed_cycle_id, failed_cycle.id);
        try std.testing.expect(!failed_cycle.pending.source);
        try std.testing.expect(!failed_cycle.pending.status);
        try std.testing.expect(!failed_cycle.pending.deferred_source_apply);
        try std.testing.expect(failed_cycle.pending.branch);
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try std.testing.expectEqual(
            source_revision_before,
            app.pages.review.source_session_revision,
        );
        try std.testing.expectEqual(
            status_revision_before,
            app.pages.review.status_snapshot_revision,
        );
        try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
        try std.testing.expect(app.pages.review.pending_reload == null);
        try std.testing.expect(app.pages.review.review_projection.pending == null);
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));

        const retry_reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
        const retry_cycle_id = retry_reads.source_cycle_id orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expect(retry_cycle_id > failed_cycle_id);
        try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, retry_reads, "MM a\x00");
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try finishCanonicalPublicationSource(
            &app,
            &ctx,
            allocator,
            retry_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&app, retry_cycle_id);
        try expectRetainedCanonicalPublication(&app, prior_hunks);
        try app.reviewRead().ensureProjection(&ctx);
        var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
        const final_bundle = try canonicalPublicationFinalBundle(allocator, request);
        try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
            .request = request,
            .result = .{ .ready = .{ .combined_hunks = final_bundle } },
        });
        request = undefined;
        try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, retry_reads);

        try std.testing.expect(app.pages.review.deferred_source_apply == null);
        try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
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
        try std.testing.expect(app.pages.review.pending_reload == null);
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
    }
}

test "Review canonical publication projection failure publishes failure body atomically" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.terminal_size.height = 12;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    const source_revision_before = app.pages.review.source_session_revision;
    const status_revision_before = app.pages.review.status_snapshot_revision;
    const prior = app.reviewNavigationView().activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    _ = try installCanonicalPublicationLineageOwners(&app, allocator, roots.a);
    const action_block = app.reviewNavigationView().selectionActionRenderBlock() orelse
        return error.ExpectedSelectionActionBlock;
    const controls_row = action_block.projection.actionPresentationRow(1) orelse
        return error.ExpectedSelectionActionControls;
    app.pages.review.viewer.diff_scroll = controls_row;
    const selection_viewport_before = app.reviewNavigationView().captureSelectionViewportAnchor() orelse
        return error.ExpectedSelectionViewportAnchor;
    try std.testing.expectEqual(controls_row, selection_viewport_before.raw_presentation_scroll);
    try std.testing.expectEqual(@as(isize, 1), selection_viewport_before.signed_screen_delta);
    switch (selection_viewport_before.semantic_source) {
        .parsed => |coordinate| app.pages.review.viewer.diff_cursor = coordinate,
        .none, .generated_row => return error.ExpectedParsedSelectionViewportSource,
    }

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    const cycle_id = reads.source_cycle_id orelse return error.ExpectedBackgroundCycle;
    try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, "MM a\x00");
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try finishCanonicalPublicationSource(
        &app,
        &ctx,
        allocator,
        reads,
        app_test_support.diff_unstaged_projection,
    );
    try expectCanonicalPublicationCycleTransfer(&app, cycle_id);
    try expectRetainedCanonicalPublication(&app, prior_hunks);

    try app.reviewRead().ensureProjection(&ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
    const expected_source_revision = request.source_session_revision;
    const expected_status_revision = request.status_snapshot_revision;
    try std.testing.expectEqual(source_revision_before + 1, expected_source_revision);
    try std.testing.expectEqual(status_revision_before, expected_status_revision);
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = request,
        .result = .{ .failed_static = "projection failed" },
    });
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

    // The publication route's failure arm commits
    // atomically — the gate is consumed, the accepted source and status are
    // published exactly once, and the preallocated failure body becomes the
    // displayed projection instead of leaving a stale retained body plus a
    // live transaction.
    try std.testing.expect(app.pages.review.canonical_publication == null);
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
    try std.testing.expectEqual(expected_source_revision, app.pages.review.source_session_revision);
    try std.testing.expectEqual(expected_status_revision, app.pages.review.status_snapshot_revision);
    switch (app.pages.review.review_projection.displayed) {
        .failed => {},
        else => return error.ExpectedFailedProjectionDisplay,
    }
    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.review_projection.pending == null);
    try std.testing.expect(app.pages.review.completed_selection == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        app.reviewNavigationView().restoredSelectionViewportScroll(selection_viewport_before),
    );
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_scroll);
    try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
}

test "Review canonical publication changed status waits for unchanged source and stale generations drain" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    const status_revision_before = app.pages.review.status_snapshot_revision;
    const source_revision_before = app.pages.review.source_session_revision;
    const prior = app.reviewNavigationView().activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const prior_review_token = app.reviewNavigationView().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try finishCanonicalPublicationAction(&app, &ctx, allocator, .stage_file, roots.a);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, "M  a\x00");

    try std.testing.expectEqual(status_revision_before, app.pages.review.status_snapshot_revision);
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("unchanged") },
    });
    try std.testing.expectEqual(source_revision_before, app.pages.review.source_session_revision);
    try expectRetainedCanonicalPublication(&app, prior_hunks);

    try app.reviewRead().ensureProjection(&ctx);
    var request = try takeCanonicalPublicationProjectionRequest(&ctx, allocator);
    var request_owned = true;
    defer if (request_owned) request.deinit(allocator);
    try std.testing.expectEqual(app_review_projection.Kind.cached_diff, request.kind);
    const stale_request = try app_review_projection.cloneRequestWithOptions(
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
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = stale_request,
        .result = .{ .ready = .{
            .cached_diff = try app_load.buildLoadedBundle(
                allocator,
                app_test_support.diff_cached_projection,
            ),
        } },
    });
    try expectRetainedCanonicalPublication(&app, prior_hunks);
    try std.testing.expect(app.pages.review.review_projection.hasPending());

    request_owned = false;
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = request,
        .result = .{ .ready = .{
            .cached_diff = try app_load.buildLoadedBundle(
                allocator,
                app_test_support.diff_cached_projection,
            ),
        } },
    });
    request = undefined;
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

    try std.testing.expectEqual(source_revision_before, app.pages.review.source_session_revision);
    try std.testing.expectEqual(status_revision_before + 1, app.pages.review.status_snapshot_revision);
    try std.testing.expect(app.reviewNavigationView().displayedReviewBody() == .cached);
    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    const published_request = app.pages.review.review_projection.displayed.request() orelse
        return error.ExpectedCanonicalProjectionRequest;
    try std.testing.expect(published_request.matchesBorrowed(
        app.pages.review.repository_read_authority.epoch,
        roots.a,
        "a",
        .cached_diff,
        .unstaged,
        source_revision_before,
        status_revision_before + 1,
    ));
    try std.testing.expect(!app.reviewNavigationView().currentContentToken().?.eql(
        prior_review_token,
    ));
    try std.testing.expect(app.pages.review.completed_selection == null);
    switch (app.reviewOperations().stageTarget()) {
        .already_staged => |path| try std.testing.expectEqualStrings("a", path),
        else => return error.ExpectedAlreadyStagedFile,
    }
    switch (app.reviewOperations().unstageTarget()) {
        .ready => |target| try std.testing.expectEqualStrings("a", target.path),
        else => return error.ExpectedFileUnstageCapability,
    }
    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(
            ToggleStageOperation.unstage,
            operation,
        ),
        else => return error.ExpectedHunkUnstageOperation,
    }
    switch (app.reviewOperations().selectedHunkStageTarget(allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedHunk,
    }
    switch (app.reviewOperations().selectedHunkUnstageTarget(allocator)) {
        .ready => |target| {
            defer allocator.free(target.patch);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expect(target.session_mark_mutation == .none);
        },
        else => return error.ExpectedHunkUnstageCapability,
    }
    try std.testing.expect(!app.pages.review.review_projection.hasPending());
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));

    {
        var mixed_app = try canonicalPublicationTestApp(allocator, roots.a);
        defer mixed_app.pages.review.deinit(allocator);
        defer mixed_app.repo_session.repo_state.deinit(allocator);
        var mixed_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        const mixed_status_revision = mixed_app.pages.review.status_snapshot_revision;
        const mixed_source_revision = mixed_app.pages.review.source_session_revision;
        const mixed_prior = mixed_app.reviewNavigationView().activeCombinedProjection() orelse
            return error.ExpectedCombinedProjection;
        const mixed_hunks = mixed_prior.displayFile().hunks.ptr;
        const mixed_content_token = mixed_prior.presentation.content_token;

        try finishCanonicalPublicationAction(
            &mixed_app,
            &mixed_ctx,
            allocator,
            .stage_file,
            roots.a,
        );
        const mixed_reads = try takeCanonicalPublicationReads(&mixed_ctx, allocator);
        try finishCanonicalPublicationStatus(
            &mixed_app,
            &mixed_ctx,
            allocator,
            roots.a,
            mixed_reads,
            "MM a\x00 M b\x00",
        );
        try mixed_app.reviewRead().finishDiffLoad(mixed_ctx.allocator(), .{
            .identity = mixed_reads.source_identity,
            .read_epoch = mixed_reads.source_read_epoch,
            .generation = mixed_reads.source_generation,
            .background_cycle_id = mixed_reads.source_cycle_id,
            .result = .{
                .unchanged = content_fingerprint.Fingerprint.init("unchanged"),
            },
        });
        try expectRetainedCanonicalPublication(&mixed_app, mixed_hunks);

        try mixed_app.reviewRead().ensureProjection(&mixed_ctx);
        var mixed_request = try takeCanonicalPublicationProjectionRequest(
            &mixed_ctx,
            allocator,
        );
        var mixed_request_owned = true;
        defer if (mixed_request_owned) mixed_request.deinit(allocator);
        try std.testing.expectEqual(
            app_review_projection.Kind.combined_hunks,
            mixed_request.kind,
        );
        const mixed_final = try canonicalPublicationFinalBundle(
            allocator,
            mixed_request,
        );
        mixed_request_owned = false;
        try mixed_app.reviewRead().finishProjectionLoad(mixed_ctx.allocator(), .{
            .request = mixed_request,
            .result = .{ .ready = .{ .combined_hunks = mixed_final } },
        });
        mixed_request = undefined;
        try finishCanonicalPublicationBranch(
            &mixed_app,
            &mixed_ctx,
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
        defer superseded_app.pages.review.deinit(allocator);
        defer superseded_app.repo_session.repo_state.deinit(allocator);
        var superseded_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        const superseded_status_revision = superseded_app.pages.review.status_snapshot_revision;
        const superseded_source_revision = superseded_app.pages.review.source_session_revision;
        const superseded_prior = superseded_app.reviewNavigationView().activeCombinedProjection() orelse
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
            &superseded_ctx,
            allocator,
            old_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectCanonicalPublicationCycleTransfer(&superseded_app, old_cycle_id);
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);

        try review_read.testing.startDiffLoadWithRepoRoot(superseded_app.reviewRead(), &superseded_ctx, roots.a, .{
            .clear_visible_state = false,
            .kind = .watch,
        });
        const new_reads = try takeCanonicalPublicationReads(&superseded_ctx, allocator);
        try std.testing.expect(new_reads.source_cycle_id == null);
        try std.testing.expect(new_reads.status_cycle_id == null);
        try std.testing.expect(new_reads.branch_cycle_id == null);
        try std.testing.expect(superseded_app.pages.review.deferred_source_apply == null);
        const draining_cycle = superseded_app.pages.review.auto_reload.background_cycle orelse
            return error.ExpectedBackgroundCycle;
        try std.testing.expectEqual(old_cycle_id, draining_cycle.id);
        try std.testing.expect(!draining_cycle.pending.source);
        try std.testing.expect(!draining_cycle.pending.deferred_source_apply);
        try std.testing.expect(draining_cycle.pending.status);
        try std.testing.expect(draining_cycle.pending.branch);

        try finishCanonicalPublicationStatus(
            &superseded_app,
            &superseded_ctx,
            allocator,
            roots.a,
            old_reads,
            "M  a\x00",
        );
        try finishCanonicalPublicationBranch(
            &superseded_app,
            &superseded_ctx,
            allocator,
            roots.a,
            old_reads,
        );
        try std.testing.expect(superseded_app.pages.review.auto_reload.background_cycle == null);
        try std.testing.expectEqual(
            superseded_source_revision,
            superseded_app.pages.review.source_session_revision,
        );
        try std.testing.expectEqual(
            superseded_status_revision,
            superseded_app.pages.review.status_snapshot_revision,
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);

        try finishCanonicalPublicationSource(
            &superseded_app,
            &superseded_ctx,
            allocator,
            new_reads,
            app_test_support.diff_unstaged_projection,
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);
        try finishCanonicalPublicationStatus(
            &superseded_app,
            &superseded_ctx,
            allocator,
            roots.a,
            new_reads,
            "MM a\x00",
        );
        try expectRetainedCanonicalPublication(&superseded_app, superseded_hunks);
        try superseded_app.reviewRead().ensureProjection(&superseded_ctx);
        var superseded_request = try takeCanonicalPublicationProjectionRequest(
            &superseded_ctx,
            allocator,
        );
        const superseded_bundle = try canonicalPublicationFinalBundle(
            allocator,
            superseded_request,
        );
        try superseded_app.reviewRead().finishProjectionLoad(superseded_ctx.allocator(), .{
            .request = superseded_request,
            .result = .{ .ready = .{ .combined_hunks = superseded_bundle } },
        });
        superseded_request = undefined;
        try finishCanonicalPublicationBranch(
            &superseded_app,
            &superseded_ctx,
            allocator,
            roots.a,
            new_reads,
        );

        try std.testing.expectEqual(
            superseded_source_revision + 1,
            superseded_app.pages.review.source_session_revision,
        );
        try std.testing.expectEqual(
            superseded_status_revision,
            superseded_app.pages.review.status_snapshot_revision,
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
        try std.testing.expect(!superseded_app.pages.review.review_projection.hasPending());
        try std.testing.expect(!superseded_app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(superseded_app.reviewRead()));
    }
}

test "background status refresh retains combined projection while cursor moves" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    acceptTestSource(&app);

    const projection_before = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.displayFile().hunks.ptr;
    const cursor_before = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_before > 0);

    _ = app.pages.review.status_load.prepare(true);
    syncTestActivation(&app);
    app.pages.review.load.generation +%= 1;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().ensureProjection(&ctx);

    const retained = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedRetainedProjection;
    try std.testing.expectEqual(hunks_before, retained.displayFile().hunks.ptr);
    app.reviewNavigation().moveDiffCursorRows(.down);
    const cursor_after = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_after > cursor_before);
    try std.testing.expect(cursor_after != 0);
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .stale_status => {},
        else => return error.ExpectedStaleProjectedHunkAuthority,
    }
}

test "unchanged full cycle preserves projection semantic identity" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 17,
            .status_snapshot_revision = 19,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = 2 },
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
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    const projection_before = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.displayFile().hunks.ptr;
    const cursor_before = app.pages.review.viewer.diff_cursor;
    const scroll_before = app.pages.review.viewer.diff_scroll;

    const status_generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(1, .{});
    app.pages.review.load.generation +%= 1;
    try std.testing.expect(app.pages.review.status_load.finishTerminal(.{
        .generation = status_generation,
        .read_epoch = .{},
        .background_cycle_id = 1,
    }));
    app.pages.review.status_load.markSuccess();

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().ensureProjection(&ctx);

    const projection_after = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    try std.testing.expectEqual(hunks_before, projection_after.displayFile().hunks.ptr);
    try std.testing.expect(!app.pages.review.review_projection.hasPending());
    try std.testing.expectEqual(@as(u64, 17), app.pages.review.source_session_revision);
    try std.testing.expectEqual(@as(u64, 19), app.pages.review.status_snapshot_revision);
    try std.testing.expectEqual(cursor_before, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.review.viewer.diff_scroll);
}

test "final projection prefers explicit interim navigation override" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const state_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.pending = state_request;
    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = 4,
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
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 4,
    };

    const result_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 0 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.reviewNavigationView().selectedDiffCursorOffset());
}

test "empty watch source carries combined navigation into cached projection" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 }, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } },
            .source_session_revision = 37,
            .status_snapshot_revision = 41,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = 3 },
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
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    const original_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(original_offset > 0);

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() != null);
    try std.testing.expectEqual(@as(usize, 0), app.reviewNavigationView().activeLoadedDiffConst().?.document.files.len);

    const staged_only = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = staged_only },
    });
    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedCachedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.cached_diff, target.kind);

    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    const result_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    const final_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(final_offset > 0);
    try std.testing.expect(final_offset <= original_offset);
}

test "empty watch source carries generated navigation into generated projection" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.pages.review.git_status.replace("/repo", &untracked);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    app.pages.review.viewer.diff_cursor = .{ .metadata = 2 };
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .watch };

    const displayed_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = displayed_request,
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\n") },
    } };
    const original_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expectEqual(@as(usize, 2), original_offset);

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);

    const same_untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same_untracked },
    });
    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedGeneratedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.generated_added_file, target.kind);

    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    const result_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\nfive\n") } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeGeneratedFileProjection() != null);
    try std.testing.expectEqual(@as(?usize, 2), app.reviewNavigationView().selectedDiffCursorOffset());
}

test "fresh empty status consumes pending display restore at raw terminal" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expectEqual(@as(u64, 1), cycle_id);
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .status));

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
}

test "selected path change supersedes pending display restore" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    app.pages.review.viewer.selected_target = .{ .status_only = 1 };
    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .status_only,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };
    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        "/repo",
        "b",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().ensureProjection(&ctx);

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.pages.review.review_projection.pending != null);
    try std.testing.expectEqualStrings("b", app.pages.review.review_projection.pending.?.path_key);
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
    defer app.pages.review.deinit(allocator);
    const activation_id = app.pageCoordinator().activateReview();

    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00M  b\x00");
    try app.pages.review.git_status.replace(roots.a, &status);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "a") },
            .selected_target_tag = .status_only,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = app.pages.review.display_navigation_input_revision,
    };
    app.pages.review.review_projection_next_id = 1;
    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        allocator,
        page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        1,
        roots.a,
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try applyReviewStateOnly(&app, allocator, .enter_file_search);
    try applyReviewStateOnly(&app, allocator, .file_search_next);
    try applyReviewStateOnly(&app, allocator, .submit_file_search);
    try runReadCoordinationTail(&app, &ctx);

    try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
    const pending = app.pages.review.review_projection.pending orelse return error.ExpectedProjectionForLaterSelection;
    try std.testing.expectEqual(@as(u64, 2), pending.id);
    try std.testing.expectEqualStrings("b", pending.path_key);

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    const result_request = try app_review_projection.testing.cloneRequestWithRootIdentity(
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
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff) } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
}

test "superseded projection completion cannot replace display" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    const stale_status_revision = app.pages.review.status_snapshot_revision - 1;
    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        stale_status_revision,
    );
    const result_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        stale_status_revision,
    );
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.review_projection.pending == null);
    try std.testing.expect(!app.pages.review.review_projection.hasDisplayed());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "old generated syntax completion drains pending and suppresses redraw" {
    const allocator = std.testing.allocator;
    const root_identity: repo_root_capability.Identity = .{ .device = 29, .inode = 31 };
    var app: ReadHarness = .{
        .allocator = allocator,
        .active_page = .review,
        .config = .{ .source = .unstaged },
    };
    defer app.pages.review.deinit(allocator);
    _ = app.pages.review.activation.activate(0, .pending, .pending, .pending);
    app.pages.review.repository_read_authority.epoch = .{ .value = 41 };
    app.pages.review.review_projection.installReady(.{
        .request = try app_review_projection.cloneRequestWithOptions(
            allocator,
            app.pages.review.activation.currentIdentity().?,
            11,
            "/repo",
            "new.zig",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{
                .read_epoch = app.pages.review.repository_read_authority.epoch,
                .root_identity = root_identity,
            },
        ),
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(
            allocator,
            "new.zig",
            "const retained = true;\n",
        ) },
    });
    const bundle = &app.pages.review.review_projection.displayed.ready.value.generated_added_file;
    bundle.decoration = .eligible;
    app.pages.review.review_projection.syntax_pending = try app_review_projection.generatedSyntaxRequestForProjection(
        allocator,
        17,
        app.pages.review.activation.currentIdentity().?,
        app.pages.review.review_projection.displayed.ready.request,
        bundle.fingerprint(),
    );
    const old_epoch = app.pages.review.repository_read_authority.epoch;
    app.pages.review.repository_read_authority.epoch = old_epoch.next();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    app.reviewRead().finishGeneratedProjectionSyntax(ctx.allocator(), .{
        .request = try app_review_projection.cloneGeneratedSyntaxRequest(
            allocator,
            app.pages.review.review_projection.syntax_pending.?,
        ),
        .snapshot_fingerprint = bundle.fingerprint(),
        .result = .{ .terminal_plain = .provider_unavailable },
    });

    try std.testing.expect(app.pages.review.review_projection.syntax_pending == null);
    try std.testing.expect(bundle.decoration == .eligible);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "cached preview keeps search input while projection is pending" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.pending = request;

    app.reviewNavigation().enterSearchMode();
    try std.testing.expect(app.pages.review.search.mode);
    setDiffSearchInput(&app, "staged");
    app.reviewNavigation().submitSearch();
    try std.testing.expect(!app.pages.review.search.mode);
    try std.testing.expect(app.pages.review.search.match == null);
    try std.testing.expectEqualStrings("staged", app.pages.review.search.query.slice());

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    const ready_request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = ready_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expectEqual(@as(?usize, 2), app.pages.review.search.match_offset);
}

test "finishDiffLoad applies active changed file filter" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 1 },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_added_deleted);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
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
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.load.state == .loaded);
    try std.testing.expect(app.pages.review.load.state.loaded.loaded.document.files.len > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.load.state.loaded.loaded.document.files.len);
}

test "finishDiffLoad initially selects first visible file node" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
}

test "finishDiffLoad initially selects first visible file after status projection" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.reviewNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.review.viewer.selected_target.?);
}

test "finishDiffLoad keeps initial visible selection intent for later status projection" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 1 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.pending_initial_first_visible_selection);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    try std.testing.expect(!app.pages.review.pending_initial_first_visible_selection);

    const loaded = app.reviewNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.review.viewer.selected_target.?);
}

test "status projection rebuild keeps selected node on same path key" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const before_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", before_path);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const after_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", after_path);
}

test "review root expansion survives status projection and retains sticky diff target" {
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
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    try std.testing.expect(loaded.visibleNodeCount() > 1);
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[loaded.visibleNodeAt(0).?].kind);
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "review root expansion status-first action refresh retains visible root children" {
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
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 3,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try installTestActionCursor(&app, std.testing.allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 1));

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(loaded.visibleNodeCount() > 1);
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "status load skips identical snapshot without rebuilding active tree" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    const tree_ptr = app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
}

test "status refresh path skips identical snapshot without rebuilding active tree" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
        } },
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "?? aa\x00");
    try app.pages.review.git_status.replace(roots.a, &current);
    const tree_ptr = app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    _ = try review_read.testing.startStatusLoadTracked(app.reviewRead(), &ctx, roots.a, .foreground, null, null);
    try std.testing.expect(app.pages.review.git_status.repo_root != null);
    try std.testing.expectEqual(@as(usize, 1), ctx._pending_tasks_with[0..ctx._pending_tasks_with_len].len);
    clearPendingStatusTasks(&ctx, allocator);

    const same = try git_status.StatusBundle.parseOwned(allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = app.pages.review.status_load.generation,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
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
    _ = app.pageCoordinator().activateReview();
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "?? old.zig\x00");
    try app.pages.review.git_status.replace(roots.a, &current);

    _ = try review_read.testing.startStatusLoadTracked(app.reviewRead(), &ctx, roots.b, .foreground, null, null);
    defer clearPendingStatusTasks(&ctx, allocator);

    try std.testing.expect(app.pages.review.git_status.repo_root == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
}

test "finishStatusLoad keeps clean repository snapshot fresh" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
    };
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const clean = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(!app.pages.review.status_load.isPending());
    try std.testing.expectEqualStrings("/repo", app.pages.review.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
}

test "background status failure retains display snapshot and marks action freshness stale" {
    var app: ReadHarness = .{ .allocator = std.testing.allocator };
    defer app.pages.review.git_status.deinit();
    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .status));
    const generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(cycle_id, .{});
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient status failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.review.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(!app.pages.review.status_load.isFresh());
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(null, .{});
    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.review.status_load.isFresh());
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 2 } } },
    };
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.load.state == .idle);
}

test "auto reload tick skips while auxiliary cycle members or mouse selection are pending" {
    var app: ReadHarness = .{};
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    app.pages.review.status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var status_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().autoReloadTick(&status_ctx);
    try std.testing.expectEqual(@as(usize, 0), status_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.review.status_load.pending = null;
    app.pages.review.branch_status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var branch_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.redraw_plan = .{};
    try app.reviewRead().autoReloadTick(&branch_ctx);
    try std.testing.expectEqual(@as(usize, 0), branch_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.review.branch_status_load.pending = null;
    app.pages.review.review_projection.pending = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        1,
        1,
    );
    var projection_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.redraw_plan = .{};
    try app.reviewRead().autoReloadTick(&projection_ctx);
    try std.testing.expectEqual(@as(usize, 0), projection_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    app.pages.review.review_projection.clearPending(std.testing.allocator);

    app.pages.review.selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } };
    var selection_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.redraw_plan = .{};
    try app.reviewRead().autoReloadTick(&selection_ctx);
    try std.testing.expectEqual(@as(usize, 0), selection_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.review.selection_owner = .none;
    const pending = beginAcceptedTestAction(&app, .stage_file);
    var action_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.redraw_plan = .{};
    try app.reviewRead().autoReloadTick(&action_ctx);
    try std.testing.expectEqual(@as(usize, 0), action_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    try std.testing.expect(app.acceptActionTerminal(pending));
    try installTestActionCursor(&app, std.testing.allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);
    var action_refresh_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    app.redraw_plan = .{};
    try app.reviewRead().autoReloadTick(&action_refresh_ctx);
    try std.testing.expectEqual(@as(usize, 0), action_refresh_ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
}

test "stale diff result does not clear newer pending reload metadata" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 2 } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.pending_reload = .{
        .generation = 2,
        .kind = .watch,
        .anchor = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
    };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.pending_reload != null);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.pending_reload.?.generation);
}

test "watch no-op diff load preserves session view state and staged hunk marks" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 3,
                .diff_horizontal_scroll = 4,
                .sidebar_horizontal_scroll = 2,
            },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const mark_key = try currentTestSessionHunkMarkKey(&app, 0);
    try app.pages.review.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);
    ownTestSourceRead(&app, 2, .watch);
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 4), app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.sidebar_horizontal_scroll);
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expect(app.pages.review.pending_reload == null);
}

test "changed watch reload restores acceptance-time navigation instead of launch anchor" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
                    .diff_scroll = 0,
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
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    const acceptance_cursor = app.pages.review.viewer.diff_cursor;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(acceptance_cursor, app.pages.review.viewer.diff_cursor);
    try std.testing.expect(app.pages.review.pending_reload == null);
    const restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(acceptance_cursor, restore.original.diff_cursor);
}

test "unchanged recovery clears its source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
                    .diff_scroll = 0,
                    .diff_horizontal_scroll = 0,
                    .sidebar_horizontal_scroll = 0,
                    .search_coordinate = null,
                },
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: transient", .{});
    const before = app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "unchanged source recovery preserves a newer auxiliary failure" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "source failed", .{});
    app.setReviewStatus("status load failed: auxiliary transient", .{});
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "auxiliary failure followed by source failure clears only the recovered source message" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "auxiliary transient" },
    });
    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.review.status.text());

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.review.status.text());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "ordinary unchanged source completion suppresses redraw" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
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
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "empty recovery clears its matching source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const old_fingerprint = content_fingerprint.Fingerprint.init("old");
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "destructive action-result failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "foreground failed" },
    });
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() == null);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "destructive manual failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .manual },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "manual failed" },
    });
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.review.load.state == .failed);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "diff task start failure invalidates accepted source and next watch cannot return unchanged" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
    };
    _ = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ctx._pending_tasks_with_len = 16;

    try std.testing.expectError(error.TaskLimitExceeded, review_read.testing.startDiffLoadWithRepoRoot(app.reviewRead(), &ctx, null, .{
        .clear_visible_state = true,
        .kind = .manual,
    }));
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.review.load.state == .failed);

    ctx._pending_tasks_with_len = 0;
    try review_read.testing.startDiffLoadWithRepoRoot(app.reviewRead(), &ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    try std.testing.expect(task.expected_fingerprint == null);
    const generation = task.generation;
    DiffLoadTask.destroy(task, std.testing.allocator);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
}

test "watch failure retains display and blocks source-derived actions until success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    const before = app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "transient failure" },
    });
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expect(app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
}

test "changed watch result arriving during mouse selection defers apply until release" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);
    try std.testing.expectEqualStrings("old", app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle.?.pending.deferred_source_apply);

    app.reviewNavigation().clearDiffSelection();
    try app.reviewRead().applyDeferredSourceIfReady(&ctx);
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "deferred changed watch captures navigation when selection ends" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);
    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);

    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    const navigation_at_apply = app.pages.review.viewer.diff_cursor;
    app.reviewNavigation().clearDiffSelection();
    try app.reviewRead().applyDeferredSourceIfReady(&ctx);

    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expectEqual(navigation_at_apply, app.pages.review.viewer.diff_cursor);
    const restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(navigation_at_apply, restore.original.diff_cursor);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "anchored reload keeps cursor when search query is present" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 2,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    setDiffSearchQuery(&app, "new");
    app.pages.review.search.match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } };
    app.pages.review.search.match_offset = 4;
    app.pages.review.load.generation = 2;
    try app.reviewReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);

    var changed = app_test_support.loadedDiffOne();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.diff_scroll);
    try std.testing.expect(app.pages.review.search.match != null);
}

test "manual reload restores anchor after visible state is cleared" {
    var current = app_test_support.loadedDiffTwo();
    current.text = "old";
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
                .diff_cursor = .{ .metadata = 0 },
                .diff_scroll = 2,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.load.generation = 2;
    try app.reviewReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);
    app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.state = .loading;

    var changed = app_test_support.loadedDiffTwo();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, app.pages.review.viewer.diff_cursor);
}

test "review root expansion survives manual reload and retains sticky target" {
    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var rooted_nodes = app_test_support.tree_rooted_nested_nodes;
    rooted_nodes[2].path_key = "a";
    rooted_nodes[3].path_key = "b";
    var current = app_test_support.loadedDiffRootedNested();
    current.tree = .{ .nodes = &rooted_nodes };
    current.text = "old";
    try current.rebuildVisibleNodes(current_arena.allocator(), false, .all);
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(current_arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.load.generation = 2;
    try app.reviewReload().beginPendingReload(std.testing.allocator, 2, .manual);
    ownTestSourceRead(&app, 2, .manual);
    app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.state = .loading;

    var changed = app_test_support.loadedDiffRootedNested();
    changed.tree = .{ .nodes = &rooted_nodes };
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 4), loaded.visibleNodeCount());
    try std.testing.expectEqual(file_tree.Node.Kind.repo_root, loaded.tree.nodes[loaded.visibleNodeAt(0).?].kind);
    try std.testing.expectEqual(@as(u16, 1), loaded.tree.nodes[loaded.visibleNodeAt(1).?].depth);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "watch no-op preserves selected path when status finishes before diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    app.pages.review.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const selected_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "watch no-op preserves selected path when status finishes after diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const selected_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "finishDiffLoad records empty diff as no changes" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
    try std.testing.expectEqual(@as(u64, 1), app.pages.review.load.generation);
}

test "finishDiffLoad projects earlier status snapshot into empty diff" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/tmp/repo", &status_bundle);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .empty,
    });

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.tree.nodes[1].target.status_entry);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target);
}

test "clean loaded status tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    _ = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace(roots.a, &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);
    ownTestSourceRead(&app, 2, .initial);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    const empty_fingerprint = content_fingerprint.Fingerprint.init("");

    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() != null);
    try std.testing.expectEqual(@as(usize, 0), app.reviewNavigation().activeLoadedDiff().?.document.files.len);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = clean },
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());

    try review_read.testing.startDiffLoadWithRepoRoot(app.reviewRead(), &ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    try std.testing.expect(task.expected_fingerprint.?.eql(empty_fingerprint));
    const generation = task.generation;
    DiffLoadTask.destroy(task, allocator);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .result = .{ .unchanged = empty_fingerprint },
    });
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
}

test "source failure before clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    ownTestSourceRead(&app, 2, .initial);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() != null);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() == null);
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.auto_reload.last_failure != null);
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.review.status.text());
}

test "source failure after clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    ownTestSourceRead(&app, 2, .initial);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "later source transient" },
    });

    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.auto_reload.last_failure != null);
}

test "empty status result tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() != null);

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(app.reviewNavigation().activeLoadedDiff() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
}

test "identical staged-only status keeps status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    const loaded_after_diff = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_diff.document.files.len);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);

    const same = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    const loaded_after_status = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_status.document.files.len);
    try std.testing.expect(loaded_after_status.visibleNodeCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);
}

test "finishRepoDiscovery records no repository as empty state" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{
            .state = .loading,
            .pending = .{ .repo_discovery = 1 },
            .generation = 1,
        } } },
    };
    _ = app.pages.review.activation.activate(0, .pending, .unavailable, .unavailable);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    defer app.repo_session.repo_state.deinit(std.testing.allocator);

    var pending = (try app.reviewRead().finishRepoDiscovery(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try std.testing.allocator.dupe(u8, "/work"),
        } } },
    })) orelse return error.ExpectedDiscoveryCommit;
    defer pending.deinit(ctx.allocator());
    switch (pending.discovery orelse return error.ExpectedDiscoveryCommit) {
        .none => |none| try std.testing.expectEqualStrings("/work", none.current_root),
        else => return error.ExpectedNoRepositoryDiscovery,
    }

    // Simulate the repository coordinator accepting the owned command. The
    // read owner then applies only its page-local no-repository consequence.
    try app.reviewRead().acceptRepoDiscoveryCommit(&ctx);

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_repository, app.pages.review.load.state.empty);
}

test "finishDiffLoad copies and frees current failed message" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    ownTestSourceRead(&app, 1, .initial);

    const message = try std.testing.allocator.dupe(u8, " failed \n");
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .failed = message },
    });

    try std.testing.expect(app.pages.review.load.state == .failed);
    try std.testing.expectEqualStrings("failed", app.pages.review.load.state.failed.message);
}

test "action cursor waits for status terminal after matching source failure" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 1 },
            .status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try installTestActionCursor(&app, std.testing.allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
    ownTestSourceRead(&app, 1, .action_result);

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .failed_static = "failed" },
    });
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
}

test "rejected old read terminals cannot consume action cursor members" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewNavigation().clearActionCursor(allocator);
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    const old_epoch = app.pages.review.repository_read_authority.epoch;
    app.pages.review.load.generation = 1;
    app.pages.review.load.pending = .{ .diff_load = 1 };
    app.pages.review.pending_reload = .{
        .generation = 1,
        .read_epoch = old_epoch,
        .kind = .action_result,
    };
    app.pages.review.status_load.generation = 2;
    app.pages.review.status_load.pending = .{
        .generation = 2,
        .read_epoch = old_epoch,
    };

    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
    app.pages.review.repository_read_authority.epoch = old_epoch.next();

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, 1),
        .read_epoch = old_epoch,
        .generation = 1,
        .result = .{ .failed_static = "old source" },
    });
    try std.testing.expect(app.pages.review.action_cursor.captureCompletion(
        app.repo_session.repo_epoch,
        .source,
        1,
    ) != null);

    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, 1),
        .read_epoch = old_epoch,
        .generation = 2,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "old status" },
    });
    try std.testing.expect(app.pages.review.action_cursor.captureCompletion(
        app.repo_session.repo_epoch,
        .status,
        2,
    ) != null);
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.status_load.pending == null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() != null);
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
    const identity = app.reviewNavigationView().selectedSidebarIdentity() orelse return error.ExpectedSidebarIdentity;
    switch (selection) {
        .directory => {
            try std.testing.expect(identity == .directory);
            try std.testing.expectEqualStrings("src", identity.directory);
        },
        .repo_root => try std.testing.expect(identity == .repo_root),
    }
    try std.testing.expectEqualStrings("src/a", app.reviewNavigationView().selectedStagePathKey().?);
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
    app.pages.review.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);

    const activation_id = app.pageCoordinator().activateReview();
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const selected_file = review_navigation.findFileNodeByPathKey(loaded, "src/a") orelse return error.ExpectedSelectedFile;
    app.reviewNavigation().selectSidebarNode(loaded, selected_file);

    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    if (order != .status_only) {
        app.pages.review.load.generation = 2;
        app.pages.review.load.pending = .{ .diff_load = 2 };
        app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    }
    try installTestActionCursor(&app, allocator, .file, "src/a", 9);
    try promoteTestActionCursorWithRequirement(
        &app,
        9,
        if (order == .status_only) .status_only else .source_and_status,
    );
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    if (order != .status_only) {
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    }

    const selection_node = switch (selection) {
        .directory => review_navigation.findNodeBySidebarIdentity(loaded, .{ .directory = "src" }),
        .repo_root => review_navigation.findNodeBySidebarIdentity(loaded, .repo_root),
    } orelse return error.ExpectedDirectoryLikeNode;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    try applyReviewStateOnly(&app, allocator, .{ .sidebar_click_node = selection_node });
    try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    try expectLaterSidebarIdentity(&app, selection);

    if (order == .source_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_only or order == .status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    } else if (order == .source_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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
        .pages = .{ .review = .{
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
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    try installTestActionCursor(&app, allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    if (status_first) {
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .empty,
        });
    } else {
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .empty,
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const directory_node = review_navigation.findNodeBySidebarIdentity(
        loaded,
        .{ .directory = "src" },
    ) orelse return error.ExpectedDirectoryNode;
    try std.testing.expectEqual(file_tree.Node.Kind.directory, loaded.tree.nodes[directory_node].kind);
    try std.testing.expectEqual(directory_node, app.pages.review.viewer.selected_node);
    // Directory restoration owns only the sidebar cursor. The body remains a
    // file/status target rather than being converted into a fake directory body.
    try std.testing.expect(app.pages.review.viewer.selected_target != null);
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
    app.pages.review.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.reviewReload().clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, "?? legacy.zig\x00");
    try app.pages.review.git_status.replace("/repo", &old_status);
    try app.reviewReload().applyStatusProjection(allocator, false, .accepted_status);
    app.pages.review.file_search.mode = true;
    try app.pages.review.file_search.input.insertSlice("legacy");
    app.reviewNavigation().rebuildFileSearchProjection(allocator);
    try std.testing.expectEqual(
        review_page.file_search.TargetKind.status_only,
        app.pages.review.file_search.focusedCandidate().?.target_kind,
    );

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    if (status_first) {
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.review.file_search.projection_available);

        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
    } else {
        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.review.file_search.projection_available);

        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    for (loaded.tree.nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.path_key, "legacy.zig"));
    }
    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expectEqualStrings("legacy", app.pages.review.file_search.input.slice());
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expect(app.pages.review.file_search.no_match);
    try std.testing.expect(app.pages.review.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqual(
        app.pages.review.accepted_sidebar_revision,
        app.pages.review.file_search.basis.?.accepted_sidebar_revision,
    );
}

test "source-first action refresh republishes file search from terminal empty status tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(false);
}

test "status-first action refresh republishes file search from terminal source tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(true);
}

test "inactive Review consumes matching action refresh terminals without shell redraw" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .active_page = .repository,
        .pages = .{ .review = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source failed" },
    });
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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
            .pages = .{ .review = .{
                .load = .{ .generation = 1, .pending = .{ .diff_load = 1 } },
                .status_load = if (peer_state == .pending)
                    .{ .generation = 2, .pending = .{ .generation = 2 } }
                else
                    .{},
            } },
        };
        const activation_id = app.pageCoordinator().activateReview();
        defer app.reviewReload().clearLoadedDiff(allocator);
        defer app.pages.review.git_status.deinit();
        defer app.reviewNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 2, false));
        }
        ownTestSourceRead(&app, 1, .action_result);
        app.pages.review.activation.queueRevalidation();

        // applySourceFailure has already consumed the task generation before
        // storing its owned diagnostic. Fail that allocation and prove the
        // captured completion still becomes a failure terminal.
        failing.fail_index = failing.alloc_index;
        var failing_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        try std.testing.expectError(error.OutOfMemory, app.reviewRead().finishDiffLoad(failing_ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 1,
            .result = .{ .failed_static = "source apply failed" },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(review_page.action_cursor.Terminal.failed, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = backing };
            try app.reviewRead().finishStatusLoad(peer_ctx.allocator(), .{
                .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
                .generation = 2,
                .repo_root = try backing.dupe(u8, "/repo"),
                .result = .{ .failed_static = "status failed" },
            });
        }

        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
        try std.testing.expect(app.pages.review.activation.hasQueuedFullRevalidation());
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
            .pages = .{ .review = .{
                .load = if (peer_state == .pending)
                    .{ .generation = 1, .pending = .{ .diff_load = 1 } }
                else
                    .{},
                .status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
            } },
        };
        const activation_id = app.pageCoordinator().activateReview();
        defer app.reviewReload().clearLoadedDiff(allocator);
        defer app.pages.review.git_status.deinit();
        defer app.reviewNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 1, false));
        } else {
            ownTestSourceRead(&app, 1, .action_result);
        }
        app.pages.review.activation.queueRevalidation();

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
        var failing_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
        bundle_owned = false;
        repo_root_owned = false;
        try std.testing.expectError(error.OutOfMemory, app.reviewRead().finishStatusLoad(failing_ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .repo_root = repo_root,
            .result = .{ .loaded = bundle },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(review_page.action_cursor.Terminal.failed, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = backing };
            try app.reviewRead().finishDiffLoad(peer_ctx.allocator(), .{
                .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
                .generation = 1,
                .result = .{ .failed_static = "source failed" },
            });
        }

        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
        try std.testing.expect(app.pages.review.activation.hasQueuedFullRevalidation());
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
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    app.pages.review.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    if (later_selection) {
        try applyReviewStateOnly(&app, allocator, .select_next_file);
        try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    }

    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status },
    });
    status = undefined;

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(if (later_selection) "b" else "a", app.reviewNavigationView().selectedStagePathKey().?);
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
            .review = .{
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
    defer app.pages.review.deinit(allocator);
    const activation_id = app.pageCoordinator().activateReview();
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 0);
    app.pages.review.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 1);
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = staged_status },
    });
    staged_status = undefined;

    // The status snapshot changes before the watched unstaged source catches
    // up, so `a` remains the selected source file for this brief interval.
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    app.pages.review.load.generation = 10;
    app.pages.review.load.pending = .{ .diff_load = 10 };
    try app.reviewReload().beginPendingReload(allocator, 10, .watch);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 10,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff) },
    });

    // The successor source no longer contains `a`; status projection now
    // materializes its staged-only row and reapplies the retained path anchor.
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);
    const current_loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const original_a_node = review_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const original_b_node = review_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    const tree_allocator = app.reviewNavigation().loadArenaAllocator() orelse return error.ExpectedLoadArena;
    const reordered_nodes = try tree_allocator.alloc(file_tree.Node, 2);
    reordered_nodes[0] = current_loaded.tree.nodes[original_b_node];
    reordered_nodes[1] = current_loaded.tree.nodes[original_a_node];
    current_loaded.tree.nodes = reordered_nodes;
    try current_loaded.rebuildVisibleNodes(tree_allocator, false, .all);
    app.pages.review.viewer.selected_node = 1;
    const a_node = review_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const b_node = review_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    try std.testing.expect(b_node < a_node);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    try app.reviewRead().ensureProjection(&ctx);
    const pending = app.pages.review.review_projection.pending orelse return error.ExpectedCachedProjection;
    try std.testing.expectEqual(app_review_projection.Kind.cached_diff, pending.kind);
    try std.testing.expectEqualStrings("a", pending.path_key);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    const result_request = try app_review_projection.testing.cloneRequestWithRootIdentity(
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
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);
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
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateReview();
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.reviewReload().clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator };
    if (later_selection) {
        try applyReviewStateOnly(&app, allocator, .select_next_file);
        try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    }
    const expected_path = if (later_selection) "b" else "a";

    if (status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);
    }

    const successor = try app_load.buildLoadedBundle(allocator, reordered_action_refresh_diff);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 2,
        .result = .{ .loaded = successor },
    });
    try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);

    if (!status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);
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
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 2, true));
    app.pages.review.status_load.pending = .{ .generation = 1 };

    // The source half may complete first. Retained pre-action status is not a
    // coherent final projection and therefore cannot consume the owner.
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false, .accepted_source);
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());

    app.pages.review.status_load.pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false, .accepted_status);
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    try std.testing.expect(app.reviewNavigation().finalizeActionCursor(std.testing.allocator));

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
}

test "action cursor survives exact status projection while source member is pending" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    app.pages.review.load.pending = .{ .diff_load = app.pages.review.load.generation + 1 };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false, .accepted_status);

    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
}

test "action cursor closes after status completion when source failed before generation" {
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "missing.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(9, .source));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
}

test "clearLoadedDiff clears session staged hunk marks" {
    const allocator = std.testing.allocator;
    var app: ReadHarness = .{
        .pages = .{ .review = .{
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
    defer app.pages.review.staged_hunks.deinit(allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));

    app.reviewReload().clearLoadedDiff(app.allocator);

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
}

test "queued Review Git reads retain the accepted root across path replacement" {
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

    try runReviewTestGit(io, accepted, &.{ "git", "init", "--initial-branch=main" });
    try accepted.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runReviewTestGit(io, accepted, &.{ "git", "add", "tracked.txt" });
    try runReviewTestGit(io, accepted, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try accepted.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\nA_UNSTAGED\n" });
    try accepted.writeFile(io, .{ .sub_path = "a-staged.txt", .data = "one\ntwo\n" });
    try runReviewTestGit(io, accepted, &.{ "git", "add", "a-staged.txt" });
    try accepted.writeFile(io, .{ .sub_path = "shared-untracked.txt", .data = "A_ONE\nA_TWO\n" });

    try runReviewTestGit(io, replacement, &.{ "git", "init", "--initial-branch=replacement" });
    try replacement.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runReviewTestGit(io, replacement, &.{ "git", "add", "tracked.txt" });
    try runReviewTestGit(io, replacement, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try replacement.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\nB_UNSTAGED\nB_ONLY\n" });
    try replacement.writeFile(io, .{ .sub_path = "b-staged.txt", .data = "one\ntwo\nthree\n" });
    try runReviewTestGit(io, replacement, &.{ "git", "add", "b-staged.txt" });
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
    defer app.pages.review.deinit(allocator);
    app.env_map = &parent_environment;
    var ctx: chasen.Ctx(ReadHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.reviewRead().startDiffLoad(&ctx, .manual);
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 3), queued.len);

    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);

    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(queued[1].ctx));
    const branch_root_observer = branch_task.root;
    const status_message = queued[0].run(queued[0].ctx, allocator, io);
    const branch_message = queued[1].run(queued[1].ctx, allocator, io);
    const source_message = queued[2].run(queued[2].ctx, allocator, io);

    var status_finished = switch (status_message) {
        .load_finished => |load| switch (load) {
            .review => |review| switch (review) {
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
            .review => |review| switch (review) {
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
            .review => |review| switch (review) {
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
    if (branch_root_observer.duplicate()) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.deinit();
        return error.ExpectedClosedRootCapability;
    } else |err| try std.testing.expectEqual(error.InvalidRootCapability, err);
}
