//! Owner-local tests for remote Git workflows.

const std = @import("std");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_push_retry = @import("../push_retry.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const effect_origin = @import("../effect_origin.zig");
const page = @import("../page.zig");
const repo_session = @import("../repo_session.zig");
const review_action_fence = @import("../pages/review/action_fence.zig");
const review_authority = @import("../diff_surface/authority.zig");
const review_selection_model = @import("../diff_surface/selection.zig");
const review_navigation = @import("../pages/review/navigation.zig");
const review_operations = @import("../pages/review/operations.zig");
const review_page = @import("../pages/review.zig");
const workflow_remote = @import("remote.zig");
const action_lifecycle = @import("action_lifecycle.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_source = @import("../../diff/source.zig");
const git_ops = @import("../git_ops.zig");
const git_backend = @import("../../git/backend.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const remote_request = @import("../remote_request.zig");

const BranchListLoadTask = app_load.BranchListLoadTask(app_message.Msg);

const RemotePages = struct {
    review: review_page.ReviewPageState = .{},
};

const RedrawPlan = struct {
    skip_requested: bool = false,
    frame_required: bool = false,

    fn resolvesToSkip(self: RedrawPlan) bool {
        return self.skip_requested and !self.frame_required;
    }
};

const RemoteHarness = struct {
    pub const Msg = app_message.Msg;

    allocator: ?std.mem.Allocator = std.testing.allocator,
    active_page: page.Id = .review,
    repo_session: repo_session.State = .{},
    pages: RemotePages = .{},
    config: struct { source: diff_source.SourceMode = .unstaged } = .{},
    action_runtime: action_lifecycle.ActionRuntime = .{},
    remote_workflow: workflow_remote.State = .{},
    env_map: ?*std.process.Environ.Map = null,
    overlay: app_state.OverlayState = .{},
    redraw_plan: RedrawPlan = .{},

    fn repoSessionView(self: *const RemoteHarness) repo_session.View {
        return self.repo_session.view();
    }

    fn reviewNavigationView(self: *const RemoteHarness) review_navigation.View {
        const body = app_shell_layout.compute(.{ .width = 100, .height = 20 }, .{ .page_bar_visible = true }).bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = body.width, .height = body.height },
        };
    }

    fn reviewNavigation(self: *RemoteHarness) review_navigation.Controller {
        const view = self.reviewNavigationView();
        return .{
            .page = &self.pages.review,
            .repo_root = view.repo_root,
            .repo_epoch = view.repo_epoch,
            .root_identity = view.root_identity,
            .source = view.source,
            .layout = view.layout,
            .diagnostics = .{ .target = &self.pages.review.status },
        };
    }

    fn reviewOperations(self: *const RemoteHarness) review_operations.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.review.activation.state,
        };
    }

    fn reviewOperationController(self: *RemoteHarness) review_operations.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .view_state = self.reviewOperations(),
        };
    }

    fn actionFence(self: *RemoteHarness) review_action_fence.Controller {
        return .{
            .read_authority = &self.pages.review.repository_read_authority,
            .activation = &self.pages.review.activation,
            .action_cursor = &self.pages.review.action_cursor,
            .auto_reload = &self.pages.review.auto_reload,
            .review_projection = &self.pages.review.review_projection,
            .deferred_projection_apply = &self.pages.review.deferred_projection_apply,
        };
    }

    fn actionLifecycle(self: *RemoteHarness) action_lifecycle.Controller {
        return .{ .runtime = &self.action_runtime, .fence = self.actionFence() };
    }

    fn actionLifecycleView(self: *const RemoteHarness) action_lifecycle.View {
        return self.action_runtime.view();
    }

    fn currentReviewActionRoot(self: *const RemoteHarness) ?[]const u8 {
        if (self.active_page != .review or
            self.pages.review.activation.currentIdentity() == null or
            diff_source.sourceIsOneShotInput(self.config.source)) return null;
        return self.repoSessionView().activeRoot();
    }

    fn effectSnapshot(self: *const RemoteHarness) effect_origin.Snapshot {
        return .{
            .active_page = self.active_page,
            .repo_epoch = self.repoSessionView().epoch(),
            .review_activation_id = self.pages.review.activation.next_activation_id,
            .repository_activation_id = 0,
            .compare_activation_id = 0,
            .push_error_instance_id = if (self.overlay.isPushError()) self.overlay.push_error_instance_id else null,
            .commit_panel_instance_id = null,
        };
    }

    fn remoteWorkflow(self: *RemoteHarness) workflow_remote.Controller {
        const snapshot = self.effectSnapshot();
        return .{
            .state = &self.remote_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.reviewOperationController(),
            .repo = self.repoSessionView(),
            .current_review_root = self.currentReviewActionRoot(),
            .env_map = self.env_map,
            .active_page = self.active_page,
            .review_origin = .{
                .page_id = .review,
                .repo_epoch = self.repoSessionView().epoch(),
                .activation_id = snapshot.review_activation_id,
            },
            .effect_snapshot = snapshot,
            .status = &self.pages.review.status,
            .overlay = &self.overlay,
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn requestPush(self: *RemoteHarness, allocator: std.mem.Allocator) !void {
        _ = try self.remoteWorkflow().requestPush(allocator);
    }

    fn requestPull(self: *RemoteHarness, allocator: std.mem.Allocator) !void {
        _ = try self.remoteWorkflow().requestPull(allocator);
    }

    fn requestFetch(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().requestFetch(ctx);
    }

    fn requestBranchSwitch(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        _ = try self.remoteWorkflow().requestBranchSwitch(ctx);
    }

    fn confirmPush(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().confirmPush(ctx);
    }

    fn confirmPull(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().confirmPull(ctx);
    }

    fn confirmBranchSwitch(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().confirmBranchSwitch(ctx);
    }

    fn cancelPushConfirmation(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().cancelPushConfirmation(allocator);
    }

    fn cancelPullConfirmation(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().cancelPullConfirmation(allocator);
    }

    fn clearBranchSwitch(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().clearBranchSwitch(allocator);
    }

    fn clearPushError(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().clearPushError(allocator);
    }

    fn clearPushForeground(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        workflow_remote.testing.clearForeground(&self.remote_workflow, allocator);
    }

    fn setPushError(self: *RemoteHarness, allocator: std.mem.Allocator, message: []const u8) !void {
        try workflow_remote.testing.setPushErrorWithRetry(self.remoteWorkflow(), allocator, message, null, false);
    }

    fn setPushErrorWithRetry(
        self: *RemoteHarness,
        allocator: std.mem.Allocator,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
        credentials_available: bool,
    ) !void {
        try workflow_remote.testing.setPushErrorWithRetry(
            self.remoteWorkflow(),
            allocator,
            message,
            retry_target,
            credentials_available,
        );
    }

    fn finishBranchListLoad(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: app_load.BranchListLoadFinished) !void {
        try self.remoteWorkflow().finishBranchListLoad(ctx.allocator(), result);
    }

    fn finishPush(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: app_actions.PushFinished) !void {
        _ = try self.remoteWorkflow().finishPush(ctx.allocator(), result);
    }

    fn finishPushForeground(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        _ = self.remoteWorkflow().finishPushForeground(ctx.allocator(), result);
    }

    fn runInteractivePush(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().runInteractivePush(ctx);
    }

    fn openPushCredentialPrompt(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().openPushCredentialPrompt(ctx);
    }

    fn cancelPushCredentialPrompt(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().cancelPushCredentialPrompt(allocator);
    }

    fn submitPushCredentials(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().submitPushCredentials(ctx);
    }

    fn setReviewStatus(self: *RemoteHarness, comptime fmt: []const u8, args: anytype) void {
        self.pages.review.status.set(fmt, args);
    }

    fn update(self: *RemoteHarness, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .action_finished => |finished| switch (finished) {
                .push => |result| _ = try self.remoteWorkflow().finishPush(ctx.allocator(), result),
                .push_foreground => |result| _ = self.remoteWorkflow().finishPushForeground(ctx.allocator(), result),
                else => return error.UnexpectedTestMessage,
            },
            .push_inspection_finished => |result| try self.remoteWorkflow().finishPushInspection(ctx, result),
            else => return error.UnexpectedTestMessage,
        }
    }
};

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
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

fn beginAcceptedTestAction(
    app: *RemoteHarness,
    kind: app_actions.ActionKind,
) app_actions.PendingAction {
    const prepared = app.actionLifecycle().prepare(kind);
    return app.actionLifecycle().acceptSpawn(
        app.allocator orelse std.testing.allocator,
        prepared,
    ).pending;
}

fn finishTestAction(
    app: *RemoteHarness,
    pending: app_actions.PendingAction,
    repo_root: []const u8,
) bool {
    return switch (app.actionLifecycle().finishExact(
        app.allocator orelse std.testing.allocator,
        pending,
        repo_root,
        app.currentReviewActionRoot(),
    )) {
        .rejected => false,
        .accepted => true,
    };
}

fn syncTestActivation(app: *RemoteHarness) void {
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

fn activateReview(app: *RemoteHarness) void {
    _ = app.pages.review.activation.activate(
        app.repo_session.repo_epoch,
        .pending,
        .pending,
        .pending,
    );
}

fn testSessionHunkMarkKey(
    source_session_revision: u64,
    display_hunk_index: usize,
) git_ops.SessionHunkMarkKey {
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

fn clearPendingBranchListTasks(
    ctx: *chasen.Ctx(RemoteHarness.Msg),
    allocator: std.mem.Allocator,
) void {
    for (ctx.takePendingTasksWith()) |entry| {
        const task: *BranchListLoadTask = @ptrCast(@alignCast(entry.ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
}

const BranchListItemSpec = struct {
    name: []const u8,
    oid: []const u8,
    current: bool = false,
};

fn branchListForTest(
    allocator: std.mem.Allocator,
    specs: []const BranchListItemSpec,
) !app_load.BranchListLoadTaskResult {
    const items = try allocator.alloc(git_backend.BranchListItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| {
        allocator.free(item.full_ref);
        allocator.free(item.name);
        allocator.free(item.oid);
    };
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

fn branchSwitchItemsForTest(
    allocator: std.mem.Allocator,
    specs: []const BranchListItemSpec,
) ![]app_state.BranchSwitchItem {
    const items = try allocator.alloc(app_state.BranchSwitchItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (specs, 0..) |spec, index| {
        items[index] = .{
            .name = try allocator.dupe(u8, spec.name),
            .oid = try allocator.dupe(u8, spec.oid),
            .current = spec.current,
        };
        initialized += 1;
    }
    return items;
}

fn installPushCredentialPromptForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
) !void {
    const repo_root = try installCurrentRepoForTest(app, allocator);
    var target = app_state.PushRetryTarget.empty();
    var target_owned = true;
    defer if (target_owned) target.deinit(allocator);
    target.repo_epoch = app.repoSessionView().epoch();
    target.root_identity = app.repoSessionView().activeIdentity().?;
    target.repo_root = try allocator.dupe(u8, repo_root);
    target.branch = try allocator.dupe(u8, "main");
    target.remote = try allocator.dupe(u8, "origin");
    target.remote_branch = try allocator.dupe(u8, "main");
    target.oid = try allocator.dupe(u8, "abc123");
    target.remote_url = try allocator.dupe(u8, "https://example.test/owner/repo.git");
    const prompt = try allocator.create(app_state.PushCredentialPrompt);
    var prompt_owned = true;
    defer if (prompt_owned) {
        prompt.deinit(allocator);
        allocator.destroy(prompt);
    };
    prompt.* = .{ .target = target, .active_field = .password };
    target_owned = false;
    try prompt.username.insertSlice("alice");
    try prompt.password.insertSlice("secret-token");
    app.remote_workflow.push_retry.state = .{ .credential_prompt = prompt };
    prompt_owned = false;
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

fn installActiveRepoForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
    root: []const u8,
) !void {
    app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state = .{
        .discovery = try testSingleRepoDiscovery(allocator, root),
    };
    errdefer {
        app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state = .{};
    }
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root);
    app.repo_session.repo_epoch +%= 1;
    if (app.repo_session.repo_epoch == 0) app.repo_session.repo_epoch = 1;
}

fn installCurrentRepoForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try installActiveRepoForTest(app, allocator, root);
    return app.repoSessionView().activeRoot().?;
}

fn repositoryIdentityForTest(app: *const RemoteHarness) remote_request.RepositoryIdentity {
    return .{
        .repo_epoch = app.repoSessionView().epoch(),
        .root_identity = app.repoSessionView().activeIdentity().?,
    };
}

const RetryTargetSpec = struct {
    mode: git_ops.PushMode = .upstream,
    branch: []const u8 = "main",
    remote: []const u8 = "origin",
    remote_branch: []const u8 = "main",
    oid: []const u8 = "abc123",
};

fn retryTargetForTest(
    app: *const RemoteHarness,
    allocator: std.mem.Allocator,
    spec: RetryTargetSpec,
) !app_state.PushRetryTarget {
    const repository = repositoryIdentityForTest(app);
    var target = app_state.PushRetryTarget.empty();
    errdefer target.deinit(allocator);
    target.repo_epoch = repository.repo_epoch;
    target.root_identity = repository.root_identity;
    target.mode = spec.mode;
    target.repo_root = try allocator.dupe(u8, app.repoSessionView().activeRoot().?);
    target.branch = try allocator.dupe(u8, spec.branch);
    target.remote = try allocator.dupe(u8, spec.remote);
    target.remote_branch = try allocator.dupe(u8, spec.remote_branch);
    target.oid = try allocator.dupe(u8, spec.oid);
    return target;
}

fn installForegroundForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
    request_id: u64,
    pending: app_actions.PendingAction,
    target: app_state.PushRetryTarget,
) !void {
    var owned_target = target;
    errdefer owned_target.deinit(allocator);
    const root = try app.repoSessionView().activeCapability().?.duplicate();
    errdefer {
        var owned_root = root;
        owned_root.deinit();
    }
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = request_id },
        .pending = pending,
        .identity = .{
            .repo_epoch = owned_target.repo_epoch,
            .root_identity = owned_target.root_identity,
            .operation_generation = 1,
        },
        .origin = .{
            .page_id = .review,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.review.activation.next_activation_id,
        },
        .root = root,
        .target = owned_target.take(),
        .warnings = .{},
    } };
}

fn runOnlyPushInspectionTaskForTest(
    app: *RemoteHarness,
    ctx: *chasen.Ctx(RemoteHarness.Msg),
    io: std.Io,
) !void {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    try app.update(msg, ctx);
}

fn deinitOnlyPushInspectionTaskForTest(
    ctx: *chasen.Ctx(RemoteHarness.Msg),
    io: std.Io,
) !repo_root_capability.RootCapability {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const task: *Task = @ptrCast(@alignCast(pending[0].ctx));
    const root_observer = task.root;
    var msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    msg.deinitUndelivered(ctx.allocator());
    return root_observer;
}

fn expectRootCapabilityOpen(observer: repo_root_capability.RootCapability) !void {
    var duplicate = try observer.duplicate();
    duplicate.deinit();
}

fn expectRootCapabilityClosed(observer: repo_root_capability.RootCapability) !void {
    if (observer.duplicate()) |unexpected| {
        var duplicate = unexpected;
        duplicate.deinit();
        return error.ExpectedClosedRootCapability;
    } else |err| try std.testing.expectEqual(error.InvalidRootCapability, err);
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
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, work);
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
test "requestPush snapshots the active branch target" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.overlay.isPushBranch());
    const confirmation = app.remote_workflow.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqualStrings(repo_root, confirmation.repo_root);
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("main", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expectEqual(git_ops.PushMode.upstream, confirmation.mode);
    try std.testing.expectEqual(@as(u32, 2), confirmation.ahead_behind.?.ahead);
    try std.testing.expectEqual(app.repoSessionView().epoch(), confirmation.repository_identity.repo_epoch);
    try std.testing.expect(app.repoSessionView().activeIdentity().?.eql(confirmation.repository_identity.root_identity));
}

test "requestPush snapshots set-upstream target for branch without upstream" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
    });
    try app.pages.review.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.overlay.isPushBranch());
    const confirmation = app.remote_workflow.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqual(git_ops.PushMode.set_upstream, confirmation.mode);
    try std.testing.expectEqualStrings(repo_root, confirmation.repo_root);
    try std.testing.expectEqualStrings("feature/topic", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("feature/topic", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expect(confirmation.ahead_behind == null);
}

test "requestPull snapshots the active branch target" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 2,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    try std.testing.expect(app.overlay.isPullBranch());
    const confirmation = app.remote_workflow.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expectEqualStrings("/repo", confirmation.repo_root);
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("main", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expectEqual(@as(u32, 0), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 2), confirmation.behind);
}

test "requestPull opens confirmation before remote refresh regardless of stale ahead behind" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    const confirmation = app.remote_workflow.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqual(@as(u32, 1), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 0), confirmation.behind);
}

test "requestBranchSwitch opens loading popup and starts identity scoped list task" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();
    defer app.clearBranchSwitch(std.testing.allocator);

    var branch_bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try app.pages.review.branch_status.replace("/repo", &branch_bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingBranchListTasks(&ctx, std.testing.allocator);

    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const task: *BranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0..ctx._pending_tasks_with_len][0].ctx));
    try std.testing.expectEqual(page.Id.review, task.origin);
    try std.testing.expectEqual(app.repo_session.repo_epoch, task.repo_epoch);
    try std.testing.expectEqual(app.pages.review.activation.next_activation_id, task.activation_id);
    try std.testing.expectEqualStrings("/repo", task.repo_root);
    try std.testing.expectEqual(app.remote_workflow.branch_switch.generation, task.generation);

    // Task admission failure rolls back the newly owned popup snapshot and
    // leaves no pending branch-list correlation behind.
    var rejected: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer rejected.pages.review.branch_status.deinit();
    defer rejected.pages.review.git_status.deinit();
    defer rejected.clearBranchSwitch(std.testing.allocator);
    var rejected_branch = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try rejected.pages.review.branch_status.replace("/repo", &rejected_branch);
    var rejected_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try rejected.pages.review.git_status.replace("/repo", &rejected_status);
    syncTestActivation(&rejected);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) RemoteHarness.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskFailure) RemoteHarness.Msg {
            return .quit;
        }
    };
    var rejected_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    for (0..16) |_| try rejected_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

    try std.testing.expectError(error.TaskLimitExceeded, rejected.requestBranchSwitch(&rejected_ctx));
    try std.testing.expect(!rejected.remote_workflow.branch_switch.hasState());
    try std.testing.expect(rejected.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!rejected.overlay.isSwitchBranch());
    try std.testing.expectEqual(@as(usize, 16), rejected_ctx.takePendingTasks().len);
}

test "requestBranchSwitch rejects untracked-only status distinctly" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();

    var branch_bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try app.pages.review.branch_status.replace("/repo", &branch_bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.txt\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expectEqualStrings("branch switch blocked: untracked files present", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "finishBranchListLoad ignores stale result and accepts matching generation" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{
            .branch_switch = .{
                .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
                .current_branch = try std.testing.allocator.dupe(u8, "main"),
                .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
                .generation = 3,
                .loading = true,
            },
            .branch_switch_load_pending = 3,
        },
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(std.testing.allocator);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = 0,
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = try branchListForTest(std.testing.allocator, &.{
            .{ .name = "main", .oid = "abc123", .current = true },
        }),
    });
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 0), app.remote_workflow.branch_switch.branches.len);

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = 0,
        .generation = 3,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = try branchListForTest(std.testing.allocator, &.{
            .{ .name = "main", .oid = "abc123", .current = true },
            .{ .name = "feature/topic", .oid = "def456", .current = false },
        }),
    });

    try std.testing.expect(!app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 2), app.remote_workflow.branch_switch.branches.len);
    try std.testing.expectEqual(@as(usize, 1), app.remote_workflow.branch_switch.selected_index);
    try std.testing.expectEqualStrings("feature/topic", app.remote_workflow.branch_switch.branches[1].name);
}

test "finishBranchListLoad rejects matching operation from stale repo epoch" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .remote_workflow = .{
            .branch_switch = .{
                .repo_root = try allocator.dupe(u8, "/repo"),
                .current_branch = try allocator.dupe(u8, "main"),
                .current_oid = try allocator.dupe(u8, "abc123"),
                .generation = 3,
                .loading = true,
            },
            .branch_switch_load_pending = 3,
        },
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(allocator);
    app.pages.review.status.set("retained", .{});
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 3,
        .activation_id = 1,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "stale failure") },
    });

    try std.testing.expectEqual(@as(?u64, 3), app.remote_workflow.branch_switch_load_pending);
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 0), app.remote_workflow.branch_switch.branches.len);
    try std.testing.expectEqualStrings("retained", app.pages.review.status.text());
}

test "stale branch-list diagnostic does not overwrite reactivated Review" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{
        .allocator = allocator,
        .remote_workflow = .{
            .branch_switch = .{
                .repo_root = try allocator.dupe(u8, "/repo"),
                .current_branch = try allocator.dupe(u8, "main"),
                .current_oid = try allocator.dupe(u8, "abc123"),
                .generation = 3,
                .loading = true,
            },
            .branch_switch_load_pending = 3,
        },
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(allocator);
    const old_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    const new_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    try std.testing.expect(old_activation != new_activation);
    app.pages.review.status.set("new Review diagnostic", .{});
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = old_activation,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "old operation failure") },
    });

    try std.testing.expect(app.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!app.remote_workflow.branch_switch.hasState());
    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expectEqualStrings("new Review diagnostic", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "confirmBranchSwitch treats current branch as no-op without clearing state" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .branch_switch = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .current_branch = try std.testing.allocator.dupe(u8, "main"),
            .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = false,
            .branches = try branchSwitchItemsForTest(std.testing.allocator, &.{
                .{ .name = "main", .oid = "abc123", .current = true },
                .{ .name = "feature", .oid = "def456", .current = false },
            }),
        } },
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(std.testing.allocator);
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.review.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.branches.len == 0);
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqualStrings("already on branch: main", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
}

test "requestPush clears previous push error details" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);
    defer app.clearPushError(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.setPushError(std.testing.allocator, "old push failure");

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.remote_workflow.push_confirmation != null);
}

test "requestPush rejects while another action is pending" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .push_confirmation = .{
            .repository_identity = .{ .repo_epoch = 0, .root_identity = .{ .device = 0, .inode = 0 } },
            .mode = .upstream,
            .repo_root = try std.testing.allocator.dupe(u8, "/old"),
            .branch = try std.testing.allocator.dupe(u8, "old-feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "old-main"),
            .oid = try std.testing.allocator.dupe(u8, "old123"),
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
        .overlay = .{ .kind = .push_branch },
    };
    defer app.cancelPushConfirmation(std.testing.allocator);
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    try app.requestPush(std.testing.allocator);

    const confirmation = app.remote_workflow.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqualStrings("/old", confirmation.repo_root);
    try std.testing.expectEqualStrings("old-feature", confirmation.branch);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "requestPull rejects while another action is pending" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .pull_confirmation = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/old"),
            .branch = try std.testing.allocator.dupe(u8, "old-feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "old-main"),
            .oid = try std.testing.allocator.dupe(u8, "old123"),
            .ahead = 0,
            .behind = 1,
        } },
        .overlay = .{ .kind = .pull_branch },
    };
    defer app.cancelPullConfirmation(std.testing.allocator);
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    try app.requestPull(std.testing.allocator);

    const confirmation = app.remote_workflow.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expectEqualStrings("/old", confirmation.repo_root);
    try std.testing.expectEqualStrings("old-feature", confirmation.branch);
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "requestFetch rejects while another action is pending" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.requestFetch(&ctx);

    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "confirmPush keeps confirmation when another action is pending" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .push_confirmation = .{
            .repository_identity = .{ .repo_epoch = 0, .root_identity = .{ .device = 0, .inode = 0 } },
            .mode = .upstream,
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .branch = try std.testing.allocator.dupe(u8, "feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "main"),
            .oid = try std.testing.allocator.dupe(u8, "abc123"),
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
        .overlay = .{ .kind = .push_branch },
    };
    defer app.cancelPushConfirmation(std.testing.allocator);
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.remote_workflow.push_confirmation != null);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "confirmPush rejects a proposal after repository authority changes" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(allocator);

    var bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.requestPush(allocator);
    app.repo_session.repo_epoch +%= 1;

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.remote_workflow.push_confirmation == null);
    try std.testing.expect(!app.overlay.isPushBranch());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("push unavailable: repository authority changed", app.pages.review.status.text());
}

test "confirmPush rejects a proposal with a stale root identity" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(allocator);

    var bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.requestPush(allocator);
    app.remote_workflow.push_confirmation.?.repository_identity.root_identity.inode +%= 1;

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.remote_workflow.push_confirmation == null);
    try std.testing.expect(!app.overlay.isPushBranch());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("push unavailable: repository authority changed", app.pages.review.status.text());
}

test "confirmPull keeps confirmation when another action is pending" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .pull_confirmation = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .branch = try std.testing.allocator.dupe(u8, "feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "main"),
            .oid = try std.testing.allocator.dupe(u8, "abc123"),
            .ahead = 0,
            .behind = 1,
        } },
        .overlay = .{ .kind = .pull_branch },
    };
    defer app.cancelPullConfirmation(std.testing.allocator);
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmPull(&ctx);

    try std.testing.expect(app.remote_workflow.pull_confirmation != null);
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "finishPush failed preserves retry target oid for credential prompt" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.clearPushError(std.testing.allocator);
    const pending = beginAcceptedTestAction(&app, .push);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishPush(&ctx, .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repoSessionView().epoch(),
            .root_identity = app.repoSessionView().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, repo_root),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "fatal: could not read Username for 'https://host': terminal prompts disabled") },
    });

    const target = app.remote_workflow.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqual(git_ops.PushMode.set_upstream, target.mode);
    try std.testing.expectEqualStrings("abc123", target.oid);
    try std.testing.expect(app.remote_workflow.push_retry.state.credentialsAvailable());
}

test "finishPush retires an exact action before dropping a mismatched operation generation" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    const pending = beginAcceptedTestAction(&app, .push);
    app.pages.review.status.set("unchanged", .{});
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    try app.finishPush(&ctx, .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repoSessionView().epoch(),
            .root_identity = app.repoSessionView().activeIdentity().?,
            .operation_generation = pending.generation + 1,
        },
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
        .result = .ok,
    });

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings("unchanged", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "credentialed push launch and runtime failure cross common action boundaries" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try installPushCredentialPromptForTest(&app, allocator);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.submitPushCredentials(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    const owner = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(app_actions.ActionKind.push, owner.kind);

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const Task = app_actions.PushTask(RemoteHarness.Msg);
    const task: *Task = @ptrCast(@alignCast(queued[0].ctx));
    try std.testing.expectEqual(owner.generation, task.pending.generation);
    try std.testing.expectEqual(owner.kind, task.pending.kind);
    const credentials = task.credentials orelse return error.ExpectedPushCredentials;
    try std.testing.expectEqualStrings("alice", credentials.username);
    try std.testing.expectEqualStrings("secret-token", credentials.password);

    const message = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try app.update(message, &ctx);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.remote_workflow.push_error_message != null);
}

test "credentialed push queue failure never creates accepted action ownership" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try installPushCredentialPromptForTest(&app, allocator);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) RemoteHarness.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskFailure) RemoteHarness.Msg {
            return .quit;
        }
    };
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    for (0..16) |_| try ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

    try std.testing.expectError(error.TaskLimitExceeded, app.submitPushCredentials(&ctx));

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), ctx.takePendingTasks().len);
}

test "clearPushError frees retained retry target" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    try app.setPushErrorWithRetry(std.testing.allocator, "failed", .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    }, true);

    app.clearPushError(std.testing.allocator);

    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
}

test "runInteractivePush rejects while another action is pending" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    defer app.clearPushError(std.testing.allocator);
    try app.setPushErrorWithRetry(std.testing.allocator, "failed", .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "main"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    }, true);
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.runInteractivePush(&ctx);

    const pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.kind);
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "push retry inspection rejects duplicate requests without losing task ownership" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("push retry inspection already running", app.pages.review.status.text());

    app.clearPushError(allocator);
    _ = try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push retry inspection spawn rollback restores the sole target" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{
        ._allocator = allocator,
        ._io = std.testing.io,
        ._pending_tasks_with_len = 16,
    };

    try std.testing.expectError(error.TaskLimitExceeded, app.runInteractivePush(&ctx));
    ctx._pending_tasks_with_len = 0;

    const restored = app.remote_workflow.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqualStrings("abc123", restored.oid);
    try std.testing.expect(app.remote_workflow.push_retry.state.credentialsAvailable());
    try std.testing.expectEqualStrings("could not start push retry inspection", app.pages.review.status.text());
}

test "push retry rejects a stale root identity before inspection admission" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    var target = try retryTargetForTest(&app, allocator, .{});
    target.root_identity.inode +%= 1;
    try app.setPushErrorWithRetry(allocator, "failed", target, true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("push retry unavailable: repository authority changed", app.pages.review.status.text());

    app.clearPushError(allocator);
    var stale_epoch = try retryTargetForTest(&app, allocator, .{});
    stale_epoch.repo_epoch +%= 1;
    try app.setPushErrorWithRetry(allocator, "failed", stale_epoch, true);
    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("push retry unavailable: repository authority changed", app.pages.review.status.text());
}

test "closing push error invalidates an in-flight inspection result" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), false);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.clearPushError(allocator);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try std.testing.expect(!app.overlay.isPushError());
}

test "undelivered push inspection completion releases its returned target" {
    const allocator = std.testing.allocator;
    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), false);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    const inspection_root = try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);

    // The App retains only non-owning correlation metadata until its own
    // teardown; the undelivered Msg was the sole owner of the returned target.
    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try expectRootCapabilityClosed(inspection_root);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "credential-bearing proxy omitted") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "PROXY-CANARY") == null);
}

test "Review reactivation discards an old push inspection completion" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    activateReview(&app);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), false);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.pages.review.activation.deactivate();
    activateReview(&app);
    app.setReviewStatus("new Review activation", .{});
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings("new Review activation", app.pages.review.status.text());
    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try std.testing.expect(!app.overlay.isPushError());
}

test "push inspection completion requires exact generation origin target and repository identity" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    const inspecting = app.remote_workflow.push_retry.state.inspecting;
    const Mismatch = enum { generation, origin, target, epoch, root };
    const mismatches = [_]Mismatch{ .generation, .origin, .target, .epoch, .root };
    for (mismatches) |mismatch| {
        var target = try retryTargetForTest(&app, allocator, .{});
        errdefer target.deinit(allocator);
        const result_root = try app.repoSessionView().activeCapability().?.duplicate();
        var finished: app_push_retry.Finished = .{
            .identity = inspecting.identity,
            .kind = inspecting.kind,
            .origin = inspecting.origin,
            .target_identity = inspecting.target_identity,
            .credentials_available = true,
            .root = result_root,
            .target = target.take(),
            .warnings = .{ .proxy_credentials_omitted = true },
            .outcome = .snapshot_valid,
        };
        switch (mismatch) {
            .generation => finished.identity.operation_generation +%= 1,
            .origin => finished.origin.activation_id +%= 1,
            .target => finished.target_identity.digest +%= 1,
            .epoch => finished.identity.repo_epoch +%= 1,
            .root => finished.identity.root_identity.inode +%= 1,
        }
        try app.remoteWorkflow().finishPushInspection(&ctx, finished);

        try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
        try std.testing.expectEqual(inspecting.identity.operation_generation, app.remote_workflow.push_retry.state.inspecting.identity.operation_generation);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "credential-bearing proxy omitted") == null);
    }

    const task_root = try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
    try expectRootCapabilityClosed(task_root);
}

test "runInteractivePush queues foreground oid refspec and owns retry target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var parent_environment = std.process.Environ.Map.init(allocator);
    var parent_environment_owned = true;
    defer if (parent_environment_owned) parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HOME", "/original-home");
    try parent_environment.put("LC_TEST", "original-locale");
    try parent_environment.put("TERM", "xterm-256color");
    try parent_environment.put("GIT_ASKPASS", "/tmp/GIT-ASKPASS-CANARY");
    try parent_environment.put("GITHUB_TOKEN", "PROVIDER-SECRET-CANARY");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");

    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushForeground(allocator);
    activateReview(&app);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{
        .mode = .set_upstream,
        .oid = repo.oid,
    }), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const foreground_root_observer = inspection_task.root;
    try expectRootCapabilityOpen(foreground_root_observer);
    try tmp.dir.rename("work", tmp.dir, "moved", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    const pending_inspection = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const inspection_msg = pending_inspection[0].run(pending_inspection[0].ctx, allocator, io);
    _ = parent_environment.swapRemove("HTTPS_PROXY");
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try std.testing.expect(app.remote_workflow.push_retry.state == .foreground);
    try std.testing.expectEqual(page.Id.review, app.remote_workflow.push_retry.state.foreground.origin.page_id);
    try std.testing.expectEqual(app.repo_session.repo_epoch, app.remote_workflow.push_retry.state.foreground.origin.repo_epoch);
    const action_owner = app.actionLifecycleView().acceptedPending() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(app_actions.ActionKind.push, action_owner.kind);
    try std.testing.expectEqual(action_owner.generation, app.remote_workflow.push_retry.state.foreground.pending.generation);
    try std.testing.expectEqual(action_owner.kind, app.remote_workflow.push_retry.state.foreground.pending.kind);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_foreground_commands_len);

    const entry = ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
    const child_cwd = switch (entry.runtimeChildCwd()) {
        .dir => |dir| dir,
        else => return error.ExpectedDescriptorCwd,
    };
    const queued_oid_output = try appGitOutputAlloc(allocator, io, child_cwd, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer allocator.free(queued_oid_output);
    try std.testing.expectEqualStrings(repo.oid, std.mem.trim(u8, queued_oid_output, " \t\r\n"));

    try parent_environment.put("HOME", "/mutated-home");
    parent_environment.deinit();
    parent_environment_owned = false;
    app.env_map = null;
    const queued_environment = entry.runtimeChildEnvironment() orelse return error.ExpectedReplacementEnvironment;
    try std.testing.expectEqualStrings("/original-home", queued_environment.get("HOME").?);
    try std.testing.expectEqualStrings("original-locale", queued_environment.get("LC_TEST").?);
    try std.testing.expectEqualStrings("xterm-256color", queued_environment.get("TERM").?);
    try std.testing.expectEqualStrings("1", queued_environment.get("GCM_INTERACTIVE").?);
    try std.testing.expect(queued_environment.get("GIT_ASKPASS") == null);
    try std.testing.expect(queued_environment.get("GITHUB_TOKEN") == null);
    try std.testing.expect(queued_environment.get("HTTPS_PROXY") == null);
    try std.testing.expectEqualStrings("git", entry.argv[0]);
    try std.testing.expectEqualStrings("push", entry.argv[9]);
    try std.testing.expectEqualStrings("--", entry.argv[10]);
    try std.testing.expectEqualStrings("origin", entry.argv[11]);
    try std.testing.expectEqual(@as(usize, 13), entry.argv.len);
    const expected_refspec = try std.fmt.allocPrint(allocator, "{s}:refs/heads/main", .{repo.oid});
    defer allocator.free(expected_refspec);
    try std.testing.expectEqualStrings(expected_refspec, entry.argv[12]);
    const expected_argv = [_][]const u8{
        "git",
        "-c",
        "credential.trace=false",
        "-c",
        "credential.traceSecrets=false",
        "-c",
        "credential.traceMsAuth=false",
        "-c",
        "credential.debug=false",
        "push",
        "--",
        "origin",
        expected_refspec,
    };
    for (entry.argv, &expected_argv) |actual, expected| try std.testing.expectEqualStrings(expected, actual);
    for (entry.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--set-upstream"));
    try expectRootCapabilityOpen(foreground_root_observer);

    const foreground_request_id = app.remote_workflow.push_retry.state.foreground.request_id;
    try app.finishPushForeground(&ctx, .{
        .request_id = foreground_request_id,
        .outcome = .{ .exited = 0 },
    });
    const status = app.pages.review.status.text();
    try std.testing.expectEqualStrings(
        "credential-bearing proxy omitted; pushed interactively: main -> origin/main",
        status,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "credential-bearing proxy omitted"));
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PROXY-CANARY") == null);
    try expectRootCapabilityClosed(foreground_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
}

test "runInteractivePush keeps retry target when foreground queue is full" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");

    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    const done = &struct {
        fn done(_: chasen.ForegroundCommandResult) RemoteHarness.Msg {
            return .quit;
        }
    }.done;
    _ = try ctx.terminal().runForegroundCommand(.{
        .argv = &.{ "sh", "-c", "true" },
        .cwd = .inherit,
        .environment = .inherit,
        .finished = done,
    });

    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }), true);

    try app.runInteractivePush(&ctx);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const inspection_root_observer = inspection_task.root;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.remote_workflow.push_retry.state.credentialsAvailable());
    try std.testing.expect(app.overlay.isPushError());
    const status = app.pages.review.status.text();
    try std.testing.expectEqualStrings("credential-bearing proxy omitted; interactive push already queued", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "credential-bearing proxy omitted"));
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PROXY-CANARY") == null);
    try expectRootCapabilityClosed(inspection_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
}

test "interactive push maps an invalid descriptor queue rejection without fallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    const pending_inspection = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(pending_inspection[0].ctx));
    const inspection_root_observer = inspection_task.root;
    const inspection_msg = pending_inspection[0].run(pending_inspection[0].ctx, allocator, io);
    _ = std.posix.system.close(inspection_root_observer.handle);
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.remote_workflow.push_retry.state.credentialsAvailable());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const status = app.pages.review.status.text();
    try std.testing.expectEqualStrings("credential-bearing proxy omitted; interactive push repository authority is invalid", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "credential-bearing proxy omitted"));
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PROXY-CANARY") == null);
    try expectRootCapabilityClosed(inspection_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
}

test "interactive push inspection warning survives a concurrent action admission" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    const pending_inspection = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(pending_inspection[0].ctx));
    const inspection_root_observer = inspection_task.root;
    const inspection_msg = pending_inspection[0].run(pending_inspection[0].ctx, allocator, io);
    _ = beginAcceptedTestAction(&app, .stage_file);
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const status = app.pages.review.status.text();
    try std.testing.expectEqualStrings("credential-bearing proxy omitted; another git action is running", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "credential-bearing proxy omitted"));
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PROXY-CANARY") == null);
    try expectRootCapabilityClosed(inspection_root_observer);
}

test "runInteractivePush stale snapshot does not queue foreground command" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var app: RemoteHarness = .{ .allocator = allocator };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = "not-current" }), false);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("push retry unavailable: branch changed; reload and try again", app.pages.review.status.text());
}

test "finishPushForeground ignores stale request id" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushForeground(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);

    const pending = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 2, pending, try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 1 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .foreground);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "finishPushForeground stale and duplicate terminals preserve newer action owner" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushForeground(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);
    app.pages.review.status.set("unchanged", .{});

    const stale = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 7, stale, try retryTargetForTest(&app, allocator, .{}));
    try std.testing.expect(finishTestAction(&app, stale, repo_root));
    const current_prepared = app.actionLifecycle().prepare(.pull);
    const current = app.actionLifecycle().acceptSpawn(allocator, current_prepared).pending;
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(app.actionLifecycleView().isAccepted(current));
    try std.testing.expectEqualStrings("unchanged", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.actionLifecycleView().isAccepted(current));
    try std.testing.expectEqualStrings("unchanged", app.pages.review.status.text());
    try std.testing.expect(finishTestAction(&app, current, ""));
}

test "interactive push foreground terminals publish proxy warning once for both modes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        mode: git_ops.PushMode,
        outcome: chasen.ForegroundCommandOutcome,
        expected: []const u8,
    }{
        .{ .mode = .upstream, .outcome = .{ .exited = 0 }, .expected = "credential-bearing proxy omitted; pushed interactively: main -> origin/main" },
        .{ .mode = .set_upstream, .outcome = .{ .exited = 3 }, .expected = "credential-bearing proxy omitted; interactive push exited: 3" },
        .{ .mode = .upstream, .outcome = .{ .signaled = 2 }, .expected = "credential-bearing proxy omitted; interactive push signal: 2" },
        .{ .mode = .set_upstream, .outcome = .{ .spawn_failed = "SPAWN-CANARY" }, .expected = "credential-bearing proxy omitted; interactive push spawn failed: SPAWN-CANARY" },
        .{ .mode = .upstream, .outcome = .{ .wait_failed = "WAIT-CANARY" }, .expected = "credential-bearing proxy omitted; interactive push wait failed: WAIT-CANARY" },
    };

    for (cases, 0..) |case, index| {
        var app: RemoteHarness = .{ .allocator = allocator };
        _ = try installCurrentRepoForTest(&app, allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushForeground(allocator);
        defer action_lifecycle.testing.clear(&app.action_runtime);
        activateReview(&app);
        const pending = beginAcceptedTestAction(&app, .push);
        try installForegroundForTest(&app, allocator, index + 1, pending, try retryTargetForTest(&app, allocator, .{ .mode = case.mode }));
        app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
        const foreground_root_observer = app.remote_workflow.push_retry.state.foreground.root;
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

        try app.finishPushForeground(&ctx, .{
            .request_id = .{ .id = index + 1 },
            .outcome = case.outcome,
        });

        const status = app.pages.review.status.text();
        try std.testing.expectEqualStrings(case.expected, status);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "credential-bearing proxy omitted"));
        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try expectRootCapabilityClosed(foreground_root_observer);
    }
}

test "interactive push foreground root survives repository replacement and closes on terminal or shutdown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "repo-a", .default_dir);
        try tmp.dir.createDir(io, "repo-b", .default_dir);
        const repo_a = try tmp.dir.realPathFileAlloc(io, "repo-a", allocator);
        defer allocator.free(repo_a);
        const repo_b = try tmp.dir.realPathFileAlloc(io, "repo-b", allocator);
        defer allocator.free(repo_b);

        var app: RemoteHarness = .{ .allocator = allocator };
        try installActiveRepoForTest(&app, allocator, repo_a);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushForeground(allocator);
        defer action_lifecycle.testing.clear(&app.action_runtime);
        activateReview(&app);
        const pending = beginAcceptedTestAction(&app, .push);
        try installForegroundForTest(&app, allocator, 41, pending, try retryTargetForTest(&app, allocator, .{}));
        const foreground_root_observer = app.remote_workflow.push_retry.state.foreground.root;
        app.pages.review.status.set("replacement status", .{});

        app.remote_workflow.repositoryInvalidationPort(&app.overlay).invalidateBeforeRepositoryReplacement(allocator);
        try std.testing.expect(app.remote_workflow.push_retry.state == .foreground);
        try installActiveRepoForTest(&app, allocator, repo_b);
        try expectRootCapabilityOpen(foreground_root_observer);

        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
        try app.finishPushForeground(&ctx, .{
            .request_id = .{ .id = 41 },
            .outcome = .{ .exited = 0 },
        });

        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expectEqualStrings("replacement status", app.pages.review.status.text());
        try expectRootCapabilityClosed(foreground_root_observer);
        try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
    }

    {
        var app: RemoteHarness = .{ .allocator = allocator };
        _ = try installCurrentRepoForTest(&app, allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer action_lifecycle.testing.clear(&app.action_runtime);
        const pending = beginAcceptedTestAction(&app, .push);
        try installForegroundForTest(&app, allocator, 42, pending, try retryTargetForTest(&app, allocator, .{}));
        const foreground_root_observer = app.remote_workflow.push_retry.state.foreground.root;

        app.remote_workflow.deinit(allocator);

        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try expectRootCapabilityClosed(foreground_root_observer);
        try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
    }
}

test "push remote inspection rejects non-HTTPS and restores retry target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "http://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var app: RemoteHarness = .{ .allocator = allocator };
    try installActiveRepoForTest(&app, allocator, repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.openPushCredentialPrompt(&ctx);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const lookup_root_observer = inspection_task.root;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.remote_workflow.push_retry.state.credentialPrompt() == null);
    try std.testing.expectEqualStrings("credential prompt is only available for HTTPS remotes", app.pages.review.status.text());
    try expectRootCapabilityClosed(lookup_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
}

test "push remote inspection transfers HTTPS URL into credential prompt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "https://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", "/usr/bin:/bin");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");

    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.cancelPushCredentialPrompt(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.openPushCredentialPrompt(&ctx);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const inspection_task: *Task = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const lookup_root_observer = inspection_task.root;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    const prompt = app.remote_workflow.push_retry.state.credentialPrompt() orelse return error.ExpectedPushCredentialPrompt;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", prompt.target.remote_url.?);
    try std.testing.expect(app.overlay.isPushCredentials());
    try std.testing.expect(app.remote_workflow.push_error_message == null);
    try expectRootCapabilityClosed(lookup_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "credential-bearing proxy omitted") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.review.status.text(), "PROXY-CANARY") == null);
}

test "prompt allocation failure restores and later replaces owned remote URL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "https://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var app: RemoteHarness = .{ .allocator = allocator };
    try installActiveRepoForTest(&app, allocator, repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}), true);

    var first_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.openPushCredentialPrompt(&first_ctx);
    const first_pending = first_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), first_pending.len);
    const Task = app_push_retry.Task(RemoteHarness.Msg);
    const first_task: *Task = @ptrCast(@alignCast(first_pending[0].ctx));
    const first_root_observer = first_task.root;
    const first_msg = first_pending[0].run(first_pending[0].ctx, allocator, io);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    try std.testing.expectError(error.OutOfMemory, app.update(first_msg, &failing_ctx));

    const restored = app.remote_workflow.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    const old_remote_url = restored.remote_url orelse return error.ExpectedRemoteUrl;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", old_remote_url);
    try std.testing.expect(app.overlay.isPushError());
    try expectRootCapabilityClosed(first_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);

    var second_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.openPushCredentialPrompt(&second_ctx);
    try runOnlyPushInspectionTaskForTest(&app, &second_ctx, io);

    const prompt = app.remote_workflow.push_retry.state.credentialPrompt() orelse return error.ExpectedPushCredentialPrompt;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", prompt.target.remote_url.?);
    app.cancelPushCredentialPrompt(allocator);
}
