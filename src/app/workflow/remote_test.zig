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
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const content_selection = @import("../diff_surface/selection.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const changes_page = @import("../pages/changes.zig");
const workflow_remote = @import("remote.zig");
const action_lifecycle = @import("action_lifecycle.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_source = @import("../../diff/source.zig");
const git_ops = @import("../git_ops.zig");
const git_remote = @import("../../git/remote.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_refs = @import("../../git/refs.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const remote_request = @import("../remote_request.zig");

const BranchListLoadTask = app_load.BranchListLoadTask(app_message.Msg);

const RemotePages = struct {
    changes: changes_page.ChangesPageState = .{},
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
    active_page: page.Id = .changes,
    repository_status: app_state.StatusMessage = .{},
    history_status: app_state.StatusMessage = .{},
    compare_status: app_state.StatusMessage = .{},
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

    fn changesNavigationView(self: *const RemoteHarness) changes_navigation.View {
        const body = app_shell_layout.compute(.{ .width = 100, .height = 20 }, .{ .page_bar_visible = true }).bodySize();
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = body.width, .height = body.height },
        };
    }

    fn changesNavigation(self: *RemoteHarness) changes_navigation.Controller {
        const view = self.changesNavigationView();
        return .{
            .page = &self.pages.changes,
            .repo_root = view.repo_root,
            .repo_epoch = view.repo_epoch,
            .root_identity = view.root_identity,
            .source = view.source,
            .layout = view.layout,
            .diagnostics = .{ .target = &self.pages.changes.status },
        };
    }

    fn changesOperations(self: *const RemoteHarness) changes_operations.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.changes.activation.state,
        };
    }

    fn changesOperationController(self: *RemoteHarness) changes_operations.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .view_state = self.changesOperations(),
        };
    }

    fn actionFence(self: *RemoteHarness) changes_action_fence.Controller {
        return .{
            .read_authority = &self.pages.changes.repository_read_authority,
            .activation = &self.pages.changes.activation,
            .action_cursor = &self.pages.changes.action_cursor,
            .auto_reload = &self.pages.changes.auto_reload,
            .changes_projection = &self.pages.changes.changes_projection,
            .deferred_projection_apply = &self.pages.changes.deferred_projection_apply,
        };
    }

    fn actionLifecycle(self: *RemoteHarness) action_lifecycle.Controller {
        return .{ .runtime = &self.action_runtime, .fence = self.actionFence() };
    }

    fn actionLifecycleView(self: *const RemoteHarness) action_lifecycle.View {
        return self.action_runtime.view();
    }

    fn currentChangesActionRoot(self: *const RemoteHarness) ?[]const u8 {
        if (self.active_page != .changes or
            self.pages.changes.activation.currentIdentity() == null) return null;
        return self.repoSessionView().activeRoot();
    }

    fn effectSnapshot(self: *const RemoteHarness) effect_origin.Snapshot {
        return .{
            .active_page = self.active_page,
            .repo_epoch = self.repoSessionView().epoch(),
            .changes_activation_id = self.pages.changes.activation.next_activation_id,
            .repository_activation_id = 0,
            .compare_activation_id = 0,
            .remote_error_instance_id = if (self.overlay.isRemoteError()) self.overlay.remote_error_instance_id else null,
            .commit_panel_instance_id = null,
        };
    }

    fn remoteWorkflow(self: *RemoteHarness) workflow_remote.Controller {
        const snapshot = self.effectSnapshot();
        return .{
            .state = &self.remote_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.changesOperationController(),
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .env_map = self.env_map,
            .active_page = self.active_page,
            .changes_origin = .{
                .page_id = .changes,
                .repo_epoch = self.repoSessionView().epoch(),
                .activation_id = snapshot.changes_activation_id,
            },
            .branch_origin = switch (self.active_page) {
                .changes, .repository => .{
                    .page_id = self.active_page,
                    .repo_epoch = self.repoSessionView().epoch(),
                    .activation_id = if (self.active_page == .changes) snapshot.changes_activation_id else snapshot.repository_activation_id,
                },
                else => null,
            },
            .repository_status = &self.repository_status,
            .history_status = &self.history_status,
            .compare_status = &self.compare_status,
            .effect_snapshot = snapshot,
            .status = &self.pages.changes.status,
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

    fn clearRemoteError(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        self.remoteWorkflow().clearRemoteError(allocator);
    }

    fn clearPushForeground(self: *RemoteHarness, allocator: std.mem.Allocator) void {
        workflow_remote.testing.clearForeground(&self.remote_workflow, allocator);
    }

    fn setRemoteError(self: *RemoteHarness, allocator: std.mem.Allocator, message: []const u8) !void {
        try workflow_remote.testing.setRemoteErrorWithRetry(self.remoteWorkflow(), allocator, .push, message, null);
    }

    fn setRemoteErrorWithRetry(
        self: *RemoteHarness,
        allocator: std.mem.Allocator,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
    ) !void {
        try workflow_remote.testing.setRemoteErrorWithRetry(
            self.remoteWorkflow(),
            allocator,
            .push,
            message,
            retry_target,
        );
    }

    fn finishBranchListLoad(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: app_load.BranchListLoadFinished) !void {
        try self.remoteWorkflow().finishBranchListLoad(ctx.allocator(), result);
    }

    fn finishPush(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: app_actions.PushFinished) !void {
        _ = try self.remoteWorkflow().finishPush(ctx.allocator(), result);
    }

    fn finishPushForeground(self: *RemoteHarness, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        _ = try self.remoteWorkflow().finishPushForeground(ctx, result);
    }

    fn runInteractivePush(self: *RemoteHarness, ctx: *chasen.Ctx(Msg)) !void {
        try self.remoteWorkflow().runInteractivePush(ctx);
    }

    fn setChangesStatus(self: *RemoteHarness, comptime fmt: []const u8, args: anytype) void {
        self.pages.changes.status.set(fmt, args);
    }

    fn update(self: *RemoteHarness, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .action_finished => |finished| switch (finished) {
                .push => |result| _ = try self.remoteWorkflow().finishPush(ctx.allocator(), result),
                .push_foreground => |result| _ = try self.remoteWorkflow().finishPushForeground(ctx, result),
                else => return error.UnexpectedTestMessage,
            },
            .push_inspection_finished => |result| try self.remoteWorkflow().finishPushInspection(ctx, result),
            .push_upstream_finalize_finished => |result| _ = self.remoteWorkflow().finishPushUpstreamFinalize(ctx.allocator(), result),
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
        app.currentChangesActionRoot(),
    )) {
        .rejected => false,
        .accepted => true,
    };
}

fn syncTestActivation(app: *RemoteHarness) void {
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

fn activateChanges(app: *RemoteHarness) void {
    _ = app.pages.changes.activation.activate(
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
            .source = content_selection.SourceBasis.init(.unstaged),
            .source_session_revision = source_session_revision,
            .display = .{ .loaded = .init("test diff") },
        },
        .display_hunk_index = display_hunk_index,
    };
}

const BranchListItemSpec = struct {
    name: []const u8,
    oid: []const u8,
    current: bool = false,
    tip_committer_unix: ?i64 = null,
};

fn branchListForTest(
    allocator: std.mem.Allocator,
    specs: []const BranchListItemSpec,
) !app_load.BranchListLoadTaskResult {
    const items = try allocator.alloc(git_refs.BranchListItem, specs.len);
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
            .tip_committer_unix = spec.tip_committer_unix,
        };
        initialized += 1;
    }
    var current: ?[]u8 = null;
    for (specs) |spec| if (spec.current) {
        current = try allocator.dupe(u8, spec.name);
        break;
    };
    return .{ .loaded = .{ .branches = items, .current = current } };
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
            .full_ref = &.{},
            .name = &.{},
            .oid = &.{},
            .current = spec.current,
            .tip_committer_unix = spec.tip_committer_unix,
        };
        initialized += 1;
        items[index].full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{spec.name});
        items[index].name = try allocator.dupe(u8, spec.name);
        items[index].oid = try allocator.dupe(u8, spec.oid);
    }
    return items;
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

fn installPushConfirmationForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
) !void {
    const repository = repositoryIdentityForTest(app);
    app.remote_workflow.push_confirmation = .{
        .repository_identity = repository,
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, app.repoSessionView().activeRoot().?),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
        .ahead_behind = .{ .ahead = 1, .behind = 0 },
    };
    app.overlay.openPushBranch();
}

fn installFetchTargetForTest(
    app: *RemoteHarness,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const repo_root = try installCurrentRepoForTest(app, allocator);
    var bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    syncTestActivation(app);
    return repo_root;
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
            .page_id = .changes,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.changes.activation.next_activation_id,
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
    const pending = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const msg = try pending[0].run(ctx.allocator(), io);
    try app.update(msg, ctx);
}

fn deinitOnlyPushInspectionTaskForTest(
    ctx: *chasen.Ctx(RemoteHarness.Msg),
    io: std.Io,
) !repo_root_capability.RootCapability {
    const pending = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    var msg = try pending[0].run(ctx.allocator(), io);
    const root_observer = msg.push_inspection_finished.root.?;
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
test "requestPush snapshots the active branch target" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
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
    defer app.pages.changes.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
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
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.pages.changes.git_status.deinit();
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 2,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.changes.git_status.replace(repo_root, &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    try std.testing.expect(app.overlay.isPullBranch());
    const confirmation = app.remote_workflow.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expectEqualStrings(repo_root, confirmation.repo_root);
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("main", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expectEqual(@as(u32, 0), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 2), confirmation.behind);
}

test "requestPull opens confirmation before remote refresh regardless of stale ahead behind" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.pages.changes.git_status.deinit();
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.changes.git_status.replace(repo_root, &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    const confirmation = app.remote_workflow.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqual(@as(u32, 1), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 0), confirmation.behind);
}

test "requestBranchSwitch opens loading popup and starts identity scoped list task" {
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
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, accepted);
    try accepted.writeFile(io, .{ .sub_path = "A.txt", .data = "accepted\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "A.txt" }, accepted);
    try runAppTestGit(allocator, io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "accepted" }, accepted);
    try runAppTestGit(allocator, io, &.{ "git", "branch", "feature/topic" }, accepted);
    try runAppTestGit(allocator, io, &.{ "git", "tag", "main" }, accepted);
    try runAppTestGit(allocator, io, &.{ "git", "tag", "feature/topic" }, accepted);
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=replacement" }, replacement);
    try replacement.writeFile(io, .{ .sub_path = "B.txt", .data = "replacement\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "B.txt" }, replacement);
    try runAppTestGit(allocator, io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "replacement" }, replacement);
    try runAppTestGit(allocator, io, &.{ "git", "branch", "replacement-only" }, replacement);
    const slot_path = try tmp.dir.realPathFileAlloc(io, "slot", allocator);
    defer allocator.free(slot_path);
    const slot_git_dir = try std.fs.path.join(allocator, &.{ slot_path, ".git" });
    defer allocator.free(slot_git_dir);
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("GIT_DIR", slot_git_dir);
    try parent_environment.put("GITFRAME_SWITCH_CANARY", "retained");

    var app: RemoteHarness = .{
        .allocator = allocator,
        .env_map = &parent_environment,
        .active_page = .repository,
    };
    try installActiveRepoForTest(&app, allocator, slot_path);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.pages.changes.git_status.deinit();
    defer app.clearBranchSwitch(allocator);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    defer chasen.testing.discardPendingTasks(RemoteHarness.Msg, &ctx);

    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_len);
    const pending = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try tmp.dir.rename("slot", tmp.dir, "physical-a", io);
    try tmp.dir.rename("replacement", tmp.dir, "slot", io);
    const task_message = try pending[0].run(allocator, io);
    const task = task_message.load_finished.shell.branch_list;
    try std.testing.expectEqual(page.Id.repository, task.origin);
    try std.testing.expectEqual(page.Id.repository, app.overlay.owner_page.?);
    try std.testing.expect(app.pages.changes.activation.currentIdentity() == null);
    try std.testing.expectEqual(app.repo_session.repo_epoch, task.repo_epoch);
    try std.testing.expectEqual(app.pages.changes.activation.next_activation_id, task.activation_id);
    try std.testing.expectEqualStrings(slot_path, task.repo_root);
    try std.testing.expectEqual(app.remote_workflow.branch_switch.generation, task.generation);
    var finished = switch (task_message) {
        .load_finished => |load| switch (load) {
            .shell => |shell| switch (shell) {
                .branch_list => |value| value,
                else => return error.ExpectedBranchListRead,
            },
            else => return error.ExpectedBranchListRead,
        },
        else => return error.ExpectedBranchListRead,
    };
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const list = switch (finished.result) {
        .loaded => |value| value,
        else => return error.ExpectedLoadedBranchList,
    };
    try std.testing.expectEqualStrings("main", list.current.?);
    var saw_accepted = false;
    var saw_replacement = false;
    for (list.branches) |branch| {
        saw_accepted = saw_accepted or std.mem.eql(u8, branch.full_ref, "refs/heads/feature/topic");
        saw_replacement = saw_replacement or std.mem.eql(u8, branch.name, "replacement-only");
        try std.testing.expect(branch.tip_committer_unix != null);
    }
    try std.testing.expect(saw_accepted);
    try std.testing.expect(!saw_replacement);

    // Apply the accepted list, then execute its exact local branch. The switch task
    // owns a second duplicate of the same physical A descriptor and a
    // selector-free environment snapshot even though the display path now
    // resolves to replacement B.
    finished_owned = false;
    try app.finishBranchListLoad(&ctx, finished);
    const expected_oid = try allocator.dupe(u8, app.remote_workflow.branch_switch.current_oid);
    defer allocator.free(expected_oid);
    try std.testing.expect(expected_oid.len == 40);
    const selected = &app.remote_workflow.branch_switch.branches[app.remote_workflow.branch_switch.selected_index];
    for ([_][]const u8{ "refs/heads/--detach", "refs/heads/-" }) |special_ref| {
        const original_ref = selected.full_ref;
        selected.full_ref = try allocator.dupe(u8, special_ref);
        defer {
            allocator.free(selected.full_ref);
            selected.full_ref = original_ref;
        }
        try app.confirmBranchSwitch(&ctx);
        try std.testing.expectEqualStrings("unsupported branch name", app.repository_status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
    }
    const DummyConfirmTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!RemoteHarness.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskStartError) RemoteHarness.Msg {
            return .quit;
        }
    };
    var saturated: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    for (0..16) |_| _ = try saturated.task().spawn(.{ .run = DummyConfirmTask.run, .failed = DummyConfirmTask.failed });
    try std.testing.expectError(error.TaskLimitExceeded, app.confirmBranchSwitch(&saturated));
    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.branch_switch_pending == null);
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqualStrings(expected_oid, app.remote_workflow.branch_switch.current_oid);
    _ = saturated.takePendingTasks();

    try app.confirmBranchSwitch(&ctx);
    try std.testing.expectEqual(page.Id.repository, app.remote_workflow.branch_switch_pending.?.owner.origin.page_id);
    const switch_entries = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), switch_entries.len);
    const switched_msg = try switch_entries[0].run(allocator, io);
    var switched = switched_msg.action_finished.switch_branch;
    defer switched.deinit(allocator);
    try std.testing.expectEqualStrings("feature/topic", switched.new_branch);
    try std.testing.expect(switched.result == .ok);
    const actual = try appGitOutputAlloc(allocator, io, accepted, &.{ "git", "symbolic-ref", "HEAD" });
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("refs/heads/feature/topic\n", actual);

    // Task admission failure rolls back the newly owned popup snapshot and
    // leaves no pending branch-list correlation behind.
    var rejected: RemoteHarness = .{ .allocator = allocator };
    try installActiveRepoForTest(&rejected, allocator, slot_path);
    defer rejected.repo_session.repo_state.deinit(allocator);
    defer rejected.pages.changes.branch_status.deinit();
    defer rejected.pages.changes.git_status.deinit();
    defer rejected.clearBranchSwitch(allocator);
    var rejected_branch = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "replacement",
    });
    try rejected.pages.changes.branch_status.replace(slot_path, &rejected_branch);
    var rejected_status = try git_status.StatusBundle.parseOwned(allocator, "");
    try rejected.pages.changes.git_status.replace(slot_path, &rejected_status);
    syncTestActivation(&rejected);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!RemoteHarness.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskStartError) RemoteHarness.Msg {
            return .quit;
        }
    };
    var rejected_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    for (0..16) |_| _ = try rejected_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

    try std.testing.expectError(error.TaskLimitExceeded, rejected.requestBranchSwitch(&rejected_ctx));
    try std.testing.expect(!rejected.remote_workflow.branch_switch.hasState());
    try std.testing.expect(rejected.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!rejected.overlay.isSwitchBranch());
    try std.testing.expectEqual(@as(usize, 16), rejected_ctx.takePendingTasks().len);
}

test "requestBranchSwitch opens picker with untracked-only status" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.pages.changes.git_status.deinit();
    defer app.clearBranchSwitch(allocator);

    var branch_bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try app.pages.changes.branch_status.replace(repo_root, &branch_bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? new.txt\x00");
    try app.pages.changes.git_status.replace(repo_root, &status_bundle);
    syncTestActivation(&app);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    defer chasen.testing.discardPendingTasks(RemoteHarness.Msg, &ctx);
    app.config.source = .{ .range = "HEAD~1..HEAD" };
    try app.requestBranchSwitch(&ctx);
    try std.testing.expect(!app.remote_workflow.branch_switch.hasState());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expectEqualStrings("branch switch unavailable for this source", app.pages.changes.status.text());
    app.config.source = .unstaged;
    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.loading);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_len);
}

test "finishBranchListLoad correlates caller repository activation and generation" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .active_page = .repository };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearBranchSwitch(allocator);
    const origin = app.remoteWorkflow().branch_origin.?;
    app.remote_workflow.branch_switch = .{
        .owner = .{ .origin = origin, .root_identity = app.repoSessionView().activeIdentity().? },
        .repo_root = try allocator.dupe(u8, repo_root),
        .generation = 3,
        .loading = true,
    };
    app.remote_workflow.branch_switch_load_pending = 3;
    app.overlay.openSwitchBranch(.repository);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    const wrong = [_]struct { origin: page.Id = .repository, epoch: u64, activation: u64 = 0, generation: u64 = 3, root: []const u8 }{
        .{ .epoch = origin.repo_epoch, .generation = 2, .root = repo_root },
        .{ .epoch = origin.repo_epoch, .origin = .changes, .root = repo_root },
        .{ .epoch = origin.repo_epoch + 1, .root = repo_root },
        .{ .epoch = origin.repo_epoch, .activation = 1, .root = repo_root },
        .{ .epoch = origin.repo_epoch, .root = "/different" },
    };
    for (wrong) |case| {
        try app.finishBranchListLoad(&ctx, .{
            .origin = case.origin,
            .repo_epoch = case.epoch,
            .activation_id = case.activation,
            .generation = case.generation,
            .repo_root = try allocator.dupe(u8, case.root),
            .result = .{ .failed_static = "unrelated failure" },
        });
        try std.testing.expectEqual(@as(?u64, 3), app.remote_workflow.branch_switch_load_pending);
        try std.testing.expect(app.remote_workflow.branch_switch.loading);
        try std.testing.expectEqualStrings("", app.repository_status.text());
    }
    try app.finishBranchListLoad(&ctx, .{
        .origin = .repository,
        .repo_epoch = origin.repo_epoch,
        .activation_id = 0,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = try branchListForTest(allocator, &.{
            .{ .name = "main", .oid = "abc123", .current = true, .tip_committer_unix = 100 },
            .{ .name = "feature/older", .oid = "def456", .tip_committer_unix = 200 },
            .{ .name = "feature/newest", .oid = "fedcba", .tip_committer_unix = 300 },
            .{ .name = "feature/unknown", .oid = "456def" },
        }),
    });
    const state = &app.remote_workflow.branch_switch;
    try std.testing.expect(app.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!state.loading);
    try std.testing.expectEqualStrings("main", state.current_branch);
    try std.testing.expectEqualStrings("abc123", state.current_oid);
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    try std.testing.expectEqualStrings("feature/newest", state.branches[0].name);
    try std.testing.expectEqualStrings("feature/older", state.branches[1].name);
    try std.testing.expect(state.branches[2].current);
    try std.testing.expect(state.branches[3].tip_committer_unix == null);
}

test "stale branch-list success cannot publish into reactivated Changes" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{};
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearBranchSwitch(allocator);
    const old = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .fresh, .fresh, .fresh);
    const origin = app.remoteWorkflow().branch_origin.?;
    app.remote_workflow.branch_switch = .{
        .owner = .{ .origin = origin, .root_identity = app.repoSessionView().activeIdentity().? },
        .repo_root = try allocator.dupe(u8, repo_root),
        .generation = 3,
        .loading = true,
    };
    app.remote_workflow.branch_switch_load_pending = 3;
    app.overlay.openSwitchBranch(.changes);
    _ = app.pages.changes.activation.activate(app.repo_session.repo_epoch, .fresh, .fresh, .fresh);
    app.pages.changes.status.set("new Changes diagnostic", .{});
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.finishBranchListLoad(&ctx, .{
        .origin = .changes,
        .repo_epoch = origin.repo_epoch,
        .activation_id = old,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = try branchListForTest(allocator, &.{.{ .name = "main", .oid = "abc", .current = true }}),
    });
    try std.testing.expect(app.remote_workflow.branch_switch_load_pending == null);
    try std.testing.expect(!app.remote_workflow.branch_switch.hasState());
    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expectEqualStrings("new Changes diagnostic", app.pages.changes.status.text());
}

test "confirmBranchSwitch treats filtered current branch as no-op and keeps caller data" {
    var app: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .branch_switch = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .current_branch = try std.testing.allocator.dupe(u8, "main"),
            .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = false,
            .branches = try branchSwitchItemsForTest(std.testing.allocator, &.{
                .{ .name = "feature", .oid = "def456", .current = false },
                .{ .name = "main", .oid = "abc123", .current = true },
            }),
        } },
        .overlay = .{ .kind = .switch_branch },
    };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    std.testing.allocator.free(app.remote_workflow.branch_switch.repo_root);
    app.remote_workflow.branch_switch.repo_root = try std.testing.allocator.dupe(u8, repo_root);
    app.remote_workflow.branch_switch.owner = .{
        .origin = app.remoteWorkflow().branch_origin.?,
        .root_identity = app.repoSessionView().activeIdentity().?,
    };
    // Current always wins over the worktree marker, including main worktrees.
    app.remote_workflow.branch_switch.branches[1].worktree_path = try std.testing.allocator.dupe(u8, repo_root);
    try app.remote_workflow.branch_switch.editQuery(std.testing.allocator, .{ .insert = 'm' });
    defer app.clearBranchSwitch(std.testing.allocator);
    defer app.pages.changes.staged_hunks.deinit(std.testing.allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.changes.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expect(app.remote_workflow.branch_switch.branches.len == 0);
    try std.testing.expect(app.pages.changes.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqualStrings("already on branch: main", app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());

    var missing_authority: RemoteHarness = .{
        .allocator = std.testing.allocator,
        .remote_workflow = .{ .branch_switch = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .current_branch = try std.testing.allocator.dupe(u8, "main"),
            .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
            .generation = 4,
            .loading = false,
            .branches = try branchSwitchItemsForTest(std.testing.allocator, &.{
                .{ .name = "feature", .oid = "def456", .current = false },
            }),
        } },
        .overlay = .{ .kind = .switch_branch },
    };
    missing_authority.remote_workflow.branch_switch.owner = .{
        .origin = missing_authority.remoteWorkflow().branch_origin.?,
        .root_identity = .{ .device = 0, .inode = 0 },
    };
    defer missing_authority.clearBranchSwitch(std.testing.allocator);
    var missing_ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };

    try missing_authority.confirmBranchSwitch(&missing_ctx);

    try std.testing.expectEqualStrings("branch switch unavailable: repository authority changed", missing_authority.pages.changes.status.text());
    try std.testing.expect(!missing_authority.remote_workflow.branch_switch.hasState());
    try std.testing.expectEqual(@as(u8, 0), missing_ctx._pending_tasks_len);
    try std.testing.expect(!missing_authority.actionLifecycleView().hasPending());
}

test "branch switch filter allocation failure preserves query rows and selected target" {
    const allocator = std.testing.allocator;
    var state: app_state.BranchSwitchState = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .branches = try branchSwitchItemsForTest(allocator, &.{
            .{ .name = "main", .oid = "abc", .current = true },
            .{ .name = "qjk-one", .oid = "def" },
            .{ .name = "qjk-two", .oid = "fed" },
        }),
    };
    defer state.deinit(allocator);
    try state.editQuery(allocator, .enter);
    try state.editQuery(allocator, .{ .insert = 'q' });
    state.selected_index = 1;
    const old_indexes = state.filter.source_indexes.ptr;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, state.editQuery(failing.allocator(), .{ .insert = 'j' }));
    try std.testing.expectEqualStrings("q", state.query.slice());
    try std.testing.expect(state.query_mode);
    try std.testing.expectEqual(@as(usize, 2), state.visibleCount());
    try std.testing.expectEqual(old_indexes, state.filter.source_indexes.ptr);
    try std.testing.expectEqualStrings("qjk-two", state.selectedItem().?.name);
}

test "worktree branch action owns its task and fences cancel reopen and stale completions" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .active_page = .repository };
    const root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.deinit(allocator);
    defer app.clearBranchSwitch(allocator);
    const owner: app_state.BranchSwitchOwner = .{
        .origin = app.remoteWorkflow().branch_origin.?,
        .root_identity = app.repoSessionView().activeIdentity().?,
    };
    app.remote_workflow.branch_switch = .{
        .owner = owner,
        .repo_root = try allocator.dupe(u8, root),
        .current_branch = try allocator.dupe(u8, "main"),
        .current_oid = try allocator.dupe(u8, "abc"),
        .generation = 8,
        .branches = try branchSwitchItemsForTest(allocator, &.{
            .{ .name = "linked", .oid = "def" },
            .{ .name = "free", .oid = "abc" },
        }),
    };
    app.remote_workflow.branch_switch.branches[0].worktree_path = try allocator.dupe(u8, "/linked");
    app.overlay.openSwitchBranch(.repository);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    const Dummy = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!app_message.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskStartError) app_message.Msg {
            return .quit;
        }
    };
    for (0..16) |_| _ = try ctx.task().spawn(.{ .run = Dummy.run, .failed = Dummy.failed });
    try std.testing.expectError(error.TaskLimitExceeded, app.confirmBranchSwitch(&ctx));
    try std.testing.expect(!app.remote_workflow.branch_switch.worktree_pending);
    try std.testing.expect(app.overlay.isSwitchBranch());
    _ = ctx.takePendingTasks();

    try app.confirmBranchSwitch(&ctx);
    try app.confirmBranchSwitch(&ctx);
    app.remoteWorkflow().moveBranchSwitchSelection(1);
    try std.testing.expectEqual(@as(usize, 0), app.remote_workflow.branch_switch.selected_index);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.branch_switch_pending == null);
    const entries = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("linked", app.remote_workflow.branch_switch.selectedItem().?.name);
    try std.testing.expectEqualStrings("/linked", app.remote_workflow.branch_switch.selectedItem().?.worktree_path.?);
    app.clearBranchSwitch(allocator);
    entries[0].discard(allocator);

    // A newly opened picker rejects the old result as well as wrong page,
    // activation, repository epoch and physical source identities.
    app.remote_workflow.branch_switch = .{
        .owner = owner,
        .repo_root = try allocator.dupe(u8, root),
        .generation = 9,
        .worktree_pending = true,
    };
    app.overlay.openSwitchBranch(.repository);
    for (0..5) |mismatch| {
        var stale_owner = owner;
        switch (mismatch) {
            0 => {},
            1 => stale_owner.origin.page_id = .changes,
            2 => stale_owner.origin.activation_id +%= 1,
            3 => stale_owner.origin.repo_epoch +%= 1,
            4 => stale_owner.root_identity.inode +%= 1,
            else => unreachable,
        }
        try std.testing.expect(app.remoteWorkflow().finishWorktreeSwitch(allocator, .{
            .owner = stale_owner,
            .generation = if (mismatch == 0) 8 else 9,
            .result = .{ .ready = .{ .discovery = try testSingleRepoDiscovery(allocator, root), .root_identity = owner.root_identity } },
        }) == null);
        try std.testing.expect(app.remote_workflow.branch_switch.worktree_pending);
    }
    var delivered = app.remoteWorkflow().finishWorktreeSwitch(allocator, .{
        .owner = owner,
        .generation = 9,
        .result = .{ .ready = .{ .discovery = try testSingleRepoDiscovery(allocator, root), .root_identity = owner.root_identity } },
    }).?;
    delivered.deinit(allocator);
    try std.testing.expect(!app.overlay.isSwitchBranch());
    // The runtime may discard a successful owned result during shutdown.
    var undelivered = app_message.Msg.loadFinished(.{ .shell = .{ .worktree_switch = .{
        .owner = owner,
        .generation = 9,
        .result = .{ .ready = .{ .discovery = try testSingleRepoDiscovery(allocator, root), .root_identity = owner.root_identity } },
    } } });
    undelivered.deinitUndelivered(allocator);
}

test "requestPush clears previous push error details" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);
    defer app.clearRemoteError(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.setRemoteError(std.testing.allocator, "old push failure");

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.remote_workflow.remote_error_message == null);
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
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
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
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
}

test "requestFetch rejects while another action is pending" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.requestFetch(&ctx);

    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
}

test "remote authentication fetch preparation and task terminals release request ownership" {
    const backing = std.testing.allocator;
    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!RemoteHarness.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskStartError) RemoteHarness.Msg {
            return .quit;
        }
    };

    // A failed descriptor duplicate happens after the proposal has moved into
    // FetchRequest but before startFetch can consume it.
    {
        var app: RemoteHarness = .{ .allocator = backing };
        _ = try installFetchTargetForTest(&app, backing);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.changes.branch_status.deinit();

        const original_handle = app.repo_session.repo_state.root.?.handle;
        app.repo_session.repo_state.root.?.handle = -1;
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = backing };
        const result = app.requestFetch(&ctx);
        app.repo_session.repo_state.root.?.handle = original_handle;

        try std.testing.expectError(error.InvalidRootCapability, result);
        try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(1));
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
        try std.testing.expectEqualStrings("fetch unavailable: repository authority could not be retained", app.pages.changes.status.text());
    }

    // Two proposal clones precede the environment map. Failing allocation 4
    // reaches a partially initialized first map entry and exercises both its
    // errdefer and the still-caller-owned FetchRequest defer.
    {
        var app: RemoteHarness = .{ .allocator = backing };
        _ = try installFetchTargetForTest(&app, backing);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.changes.branch_status.deinit();

        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 4 });
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = failing.allocator() };
        try std.testing.expectError(error.OutOfMemory, app.requestFetch(&ctx));

        try std.testing.expect(failing.has_induced_failure);
        try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(1));
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
        try std.testing.expectEqualStrings("could not prepare background fetch", app.pages.changes.status.text());
    }

    // startFetch is the transfer boundary. Queue rejection consumes the
    // request and destroys the initialized task; no controller owner remains.
    {
        var app: RemoteHarness = .{ .allocator = backing };
        _ = try installFetchTargetForTest(&app, backing);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.changes.branch_status.deinit();

        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = backing };
        for (0..16) |_| _ = try ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
        try std.testing.expectError(error.TaskLimitExceeded, app.requestFetch(&ctx));

        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(1));
        try std.testing.expectEqual(@as(usize, 16), ctx.takePendingTasks().len);
        try std.testing.expectEqualStrings("could not start fetch task", app.pages.changes.status.text());
    }

    // Accepted ownership closes through the same task epilogue when Chasen
    // abandons a queued-but-unstarted task during runtime unwind.
    {
        var app: RemoteHarness = .{ .allocator = backing };
        const repo_root = try installFetchTargetForTest(&app, backing);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.changes.branch_status.deinit();

        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = backing };
        try app.requestFetch(&ctx);
        const pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingAction;
        const queued = ctx.takePendingTasks();
        try std.testing.expectEqual(@as(usize, 1), queued.len);
        const msg = queued[0].failed(error.ConcurrencyUnavailable, backing);
        const finished = switch (msg) {
            .action_finished => |action| switch (action) {
                .fetch => |fetch| fetch,
                else => return error.ExpectedFetchTerminal,
            },
            else => return error.ExpectedFetchTerminal,
        };
        _ = app.remoteWorkflow().finishFetch(backing, finished);

        try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(pending.generation));
        try std.testing.expectEqualStrings(repo_root, app.repoSessionView().activeRoot().?);
    }
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
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
}

test "confirmPush rejects a proposal after repository authority changes" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.cancelPushConfirmation(allocator);

    var bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.requestPush(allocator);
    app.repo_session.repo_epoch +%= 1;

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.remote_workflow.push_confirmation == null);
    try std.testing.expect(!app.overlay.isPushBranch());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expectEqualStrings("push unavailable: repository authority changed", app.pages.changes.status.text());
}

test "confirmPush rejects a proposal with a stale root identity" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.changes.branch_status.deinit();
    defer app.cancelPushConfirmation(allocator);

    var bundle = try branchStatusBundleForTest(allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.changes.branch_status.replace(repo_root, &bundle);
    syncTestActivation(&app);
    try app.requestPush(allocator);
    app.remote_workflow.push_confirmation.?.repository_identity.root_identity.inode +%= 1;

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.remote_workflow.push_confirmation == null);
    try std.testing.expect(!app.overlay.isPushBranch());
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expectEqualStrings("push unavailable: repository authority changed", app.pages.changes.status.text());
}

test "background remote task rejection and abandonment release owned authorities" {
    const allocator = std.testing.allocator;
    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!RemoteHarness.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskStartError) RemoteHarness.Msg {
            return .quit;
        }
    };

    {
        var app: RemoteHarness = .{ .allocator = allocator };
        _ = try installCurrentRepoForTest(&app, allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.cancelPushConfirmation(allocator);
        try installPushConfirmationForTest(&app, allocator);
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
        for (0..16) |_| _ = try ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

        try std.testing.expectError(error.TaskLimitExceeded, app.confirmPush(&ctx));
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(1));
        try std.testing.expect(app.remote_workflow.push_confirmation == null);
        try std.testing.expect(!app.overlay.isPushBranch());
        try std.testing.expectEqual(@as(usize, 16), ctx.takePendingTasks().len);
    }

    {
        var app: RemoteHarness = .{ .allocator = allocator };
        _ = try installCurrentRepoForTest(&app, allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearRemoteError(allocator);
        try installPushConfirmationForTest(&app, allocator);
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

        try app.confirmPush(&ctx);
        const owner = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingAction;
        try std.testing.expect(app.remote_workflow.action_control.isActive(owner.generation));
        const queued = ctx.takePendingTasks();
        try std.testing.expectEqual(@as(usize, 1), queued.len);
        const abandoned = queued[0].failed(error.ConcurrencyUnavailable, allocator);
        try app.update(abandoned, &ctx);

        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expect(!app.remote_workflow.action_control.isActive(owner.generation));
        try std.testing.expect(app.remote_workflow.remote_error_message != null);
    }
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
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
}

test "finishPush failed preserves retry target oid for interactive push" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    const repo_root = try installCurrentRepoForTest(&app, std.testing.allocator);
    defer app.repo_session.repo_state.deinit(std.testing.allocator);
    defer app.clearRemoteError(std.testing.allocator);
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
        .result = .{ .outcome = .{ .failed = .authentication_required } },
    });

    const target = app.remote_workflow.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqual(git_ops.PushMode.set_upstream, target.mode);
    try std.testing.expectEqualStrings("abc123", target.oid);
}

test "finishPush retires an exact action before dropping a mismatched operation generation" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    const pending = beginAcceptedTestAction(&app, .push);
    app.pages.changes.status.set("unchanged", .{});
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
        .result = .{ .outcome = .{ .ok = .completed } },
    });

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings("unchanged", app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
}

test "remote cancel terminal drops retry authority and requires reload before deferred quit" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    activateChanges(&app);

    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.action_control.begin(pending.generation);
    const controller = app.remoteWorkflow();
    try std.testing.expect(controller.cancelActiveRemote(true));
    try std.testing.expect(controller.view().canceling());
    try std.testing.expectEqualStrings("canceling...", app.pages.changes.status.text());
    try std.testing.expect(controller.cancelActiveRemote(true));

    const outcome = try controller.finishPush(allocator, .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repoSessionView().epoch(),
            .root_identity = app.repoSessionView().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
        .result = .{
            .outcome = .{ .failed = .canceled_outcome_unknown },
        },
    });

    try std.testing.expectEqual(changes_action_fence.ReloadIntent.source_and_aux, outcome.reload);
    try std.testing.expect(outcome.quit_after_terminal);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!controller.view().canceling());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(std.mem.indexOf(u8, app.remote_workflow.remote_error_message.?, "outcome is unknown") != null);
}

test "remote timeout terminal drops retry authority and requires reload" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    activateChanges(&app);

    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.action_control.begin(pending.generation);
    const outcome = try app.remoteWorkflow().finishPush(allocator, .{
        .pending = pending,
        .identity = .{
            .repo_epoch = app.repoSessionView().epoch(),
            .root_identity = app.repoSessionView().activeIdentity().?,
            .operation_generation = pending.generation,
        },
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
        .result = .{
            .outcome = .{ .failed = .timed_out_outcome_unknown },
        },
    });

    try std.testing.expectEqual(changes_action_fence.ReloadIntent.source_and_aux, outcome.reload);
    try std.testing.expect(!outcome.quit_after_terminal);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(std.mem.indexOf(u8, app.remote_workflow.remote_error_message.?, "timed out") != null);
}

test "clearRemoteError frees retained retry target" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    try app.setRemoteErrorWithRetry(std.testing.allocator, "failed", .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    });

    app.clearRemoteError(std.testing.allocator);

    try std.testing.expect(app.remote_workflow.remote_error_message == null);
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
}

test "runInteractivePush rejects while another action is pending" {
    var app: RemoteHarness = .{ .allocator = std.testing.allocator };
    defer app.clearRemoteError(std.testing.allocator);
    try app.setRemoteErrorWithRetry(std.testing.allocator, "failed", .{
        .repo_epoch = 0,
        .root_identity = .{ .device = 0, .inode = 0 },
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "main"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    });
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);

    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = std.testing.allocator };
    try app.runInteractivePush(&ctx);

    const pending = app.actionLifecycleView().acceptedPending() orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.kind);
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expectEqualStrings("another git action is running", app.pages.changes.status.text());
}

test "push retry inspection rejects duplicate requests without losing task ownership" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_len);
    try std.testing.expectEqualStrings("push retry inspection already running", app.pages.changes.status.text());

    app.clearRemoteError(allocator);
    _ = try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push retry inspection spawn rollback restores the sole target" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{
        ._allocator = allocator,
        ._io = std.testing.io,
        ._pending_tasks_len = 16,
    };

    try std.testing.expectError(error.TaskLimitExceeded, app.runInteractivePush(&ctx));
    ctx._pending_tasks_len = 0;

    const restored = app.remote_workflow.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqualStrings("abc123", restored.oid);
    try std.testing.expectEqualStrings("could not start push retry inspection", app.pages.changes.status.text());
}

test "push retry rejects a stale root identity before inspection admission" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    var target = try retryTargetForTest(&app, allocator, .{});
    target.root_identity.inode +%= 1;
    try app.setRemoteErrorWithRetry(allocator, "failed", target);
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("push retry unavailable: repository authority changed", app.pages.changes.status.text());

    app.clearRemoteError(allocator);
    var stale_epoch = try retryTargetForTest(&app, allocator, .{});
    stale_epoch.repo_epoch +%= 1;
    try app.setRemoteErrorWithRetry(allocator, "failed", stale_epoch);
    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("push retry unavailable: repository authority changed", app.pages.changes.status.text());
}

test "closing push error invalidates an in-flight inspection result" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.clearRemoteError(allocator);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(app.remote_workflow.remote_error_message == null);
    try std.testing.expect(!app.overlay.isRemoteError());
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
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    const inspection_root = try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);

    // The App retains only non-owning correlation metadata until its own
    // teardown; the undelivered Msg was the sole owner of the returned target.
    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try expectRootCapabilityClosed(inspection_root);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), "warning: credential-bearing proxy was omitted") == null);
    try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), "PROXY-CANARY") == null);
}

test "Changes reactivation discards an old push inspection completion" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    activateChanges(&app);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.pages.changes.activation.deactivate();
    activateChanges(&app);
    app.setChangesStatus("new Changes activation", .{});
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings("new Changes activation", app.pages.changes.status.text());
    try std.testing.expect(app.remote_workflow.remote_error_message == null);
    try std.testing.expect(!app.overlay.isRemoteError());
}

test "push inspection completion requires exact generation origin target and repository identity" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{}));
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
            .origin = inspecting.origin,
            .target_identity = inspecting.target_identity,
            .root = result_root,
            .target = target.take(),
            .warnings = .{ .proxy_credentials_omitted = true },
            .outcome = .ready,
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
        try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), "warning: credential-bearing proxy was omitted") == null);
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
    try parent_environment.put("GITHUB_TOKEN", "PROVIDER-SECRET-CANARY");
    try parent_environment.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");

    var app: RemoteHarness = .{ .allocator = allocator, .env_map = &parent_environment };
    try installActiveRepoForTest(&app, allocator, repo.repo_root);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushForeground(allocator);
    activateChanges(&app);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{
        .mode = .set_upstream,
        .oid = repo.oid,
    }));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_len);
    try tmp.dir.rename("work", tmp.dir, "moved", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    const pending_inspection = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const inspection_msg = try pending_inspection[0].run(allocator, io);
    const foreground_root_observer = inspection_msg.push_inspection_finished.root.?;
    _ = parent_environment.swapRemove("HTTPS_PROXY");
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.remote_error_message == null);
    try std.testing.expect(app.remote_workflow.push_retry.state == .foreground);
    try std.testing.expectEqual(page.Id.changes, app.remote_workflow.push_retry.state.foreground.origin.page_id);
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

    const foreground_request_id = app.remote_workflow.push_retry.state.foreground.request_id;
    try app.finishPushForeground(&ctx, .{
        .request_id = foreground_request_id,
        .outcome = .{ .exited = 0 },
    });
    try std.testing.expect(app.remote_workflow.push_retry.state == .finalizing);
    try std.testing.expectEqualStrings("finalizing upstream...", app.pages.changes.status.text());
    const pending_finalizer = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending_finalizer.len);
    const finalizer_message = try pending_finalizer[0].run(allocator, io);
    try app.update(finalizer_message, &ctx);
    const status = app.pages.changes.status.text();
    try std.testing.expectEqualStrings(
        "warning: credential-bearing proxy was omitted; push completed; local upstream configured",
        status,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PROXY-CANARY") == null);
    try expectRootCapabilityClosed(foreground_root_observer);
    try expectRootCapabilityOpen(app.repoSessionView().activeCapability().?.*);
}

test "upstream finalization queue rejection publishes partial success once without retry" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.remote_workflow.deinit(allocator);
    activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 71, pending, try retryTargetForTest(&app, allocator, .{ .mode = .set_upstream }));
    app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
    const root_observer = app.remote_workflow.push_retry.state.foreground.root;
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_len = 16,
    };

    const outcome = try app.remoteWorkflow().finishPushForeground(&ctx, .{
        .request_id = .{ .id = 71 },
        .outcome = .{ .exited = 0 },
    });
    ctx._pending_tasks_len = 0;

    const status = app.pages.changes.status.text();
    try std.testing.expectEqual(changes_action_fence.ReloadIntent.source_and_aux, outcome.reload);
    try std.testing.expect(!outcome.quit_after_terminal);
    try std.testing.expectEqualStrings(
        "warning: credential-bearing proxy was omitted; push succeeded; local upstream was not configured; repository reload required",
        status,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.overlay.isRemoteError());
    try expectRootCapabilityClosed(root_observer);
}

test "upstream finalization runtime abandonment defers quit and discards retry authority" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.remote_workflow.deinit(allocator);
    activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 72, pending, try retryTargetForTest(&app, allocator, .{ .mode = .set_upstream }));
    app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
    const root_observer = app.remote_workflow.push_retry.state.foreground.root;
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    _ = try app.remoteWorkflow().finishPushForeground(&ctx, .{
        .request_id = .{ .id = 72 },
        .outcome = .{ .exited = 0 },
    });
    try std.testing.expect(app.remote_workflow.push_retry.state == .finalizing);
    try std.testing.expect(app.remoteWorkflow().cancelActiveRemote(true));
    const queued = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const message = queued[0].failed(error.ConcurrencyUnavailable, allocator);
    const finished = switch (message) {
        .push_upstream_finalize_finished => |result| result,
        else => return error.ExpectedUpstreamFinalizeTerminal,
    };
    const outcome = app.remoteWorkflow().finishPushUpstreamFinalize(allocator, finished);

    const status = app.pages.changes.status.text();
    try std.testing.expectEqual(changes_action_fence.ReloadIntent.source_and_aux, outcome.reload);
    try std.testing.expect(outcome.quit_after_terminal);
    try std.testing.expectEqualStrings(
        "warning: credential-bearing proxy was omitted; push succeeded; local upstream was not configured; repository reload required",
        status,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(!app.overlay.isRemoteError());
    try expectRootCapabilityClosed(root_observer);
}

test "upstream finalization shutdown drops an undelivered terminal after releasing task ownership" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    _ = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);
    activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 74, pending, try retryTargetForTest(&app, allocator, .{ .mode = .set_upstream }));
    app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
    const root_observer = app.remote_workflow.push_retry.state.foreground.root;
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    _ = try app.remoteWorkflow().finishPushForeground(&ctx, .{
        .request_id = .{ .id = 74 },
        .outcome = .{ .exited = 0 },
    });
    try std.testing.expect(app.remote_workflow.push_retry.state == .finalizing);
    const queued = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    queued[0].discard(allocator);

    try std.testing.expectEqualStrings("finalizing upstream...", app.pages.changes.status.text());
    try std.testing.expect(std.mem.indexOf(u8, app.pages.changes.status.text(), "warning:") == null);
    try expectRootCapabilityClosed(root_observer);
    app.remote_workflow.deinit(allocator);
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
}

test "upstream finalization stale completion closes ownership without current publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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
    defer app.remote_workflow.deinit(allocator);
    activateChanges(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    try installForegroundForTest(&app, allocator, 73, pending, try retryTargetForTest(&app, allocator, .{ .mode = .set_upstream }));
    app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
    const root_observer = app.remote_workflow.push_retry.state.foreground.root;
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

    _ = try app.remoteWorkflow().finishPushForeground(&ctx, .{
        .request_id = .{ .id = 73 },
        .outcome = .{ .exited = 0 },
    });
    const queued = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try installActiveRepoForTest(&app, allocator, repo_b);
    app.pages.changes.status.set("replacement status", .{});
    const message = queued[0].failed(error.ConcurrencyUnavailable, allocator);
    const finished = switch (message) {
        .push_upstream_finalize_finished => |result| result,
        else => return error.ExpectedUpstreamFinalizeTerminal,
    };
    const outcome = app.remoteWorkflow().finishPushUpstreamFinalize(allocator, finished);

    try std.testing.expectEqual(changes_action_fence.ReloadIntent.none, outcome.reload);
    try std.testing.expect(!outcome.quit_after_terminal);
    try std.testing.expectEqualStrings("replacement status", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.skip_requested);
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try expectRootCapabilityClosed(root_observer);
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
    defer app.clearRemoteError(allocator);
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

    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }));

    try app.runInteractivePush(&ctx);
    const inspection_entries = ctx.takePendingTasks();
    const inspection_message = try inspection_entries[0].run(allocator, io);
    const inspection_root_observer = inspection_message.push_inspection_finished.root.?;
    try app.update(inspection_message, &ctx);

    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.overlay.isRemoteError());
    const status = app.pages.changes.status.text();
    try std.testing.expectEqualStrings("warning: credential-bearing proxy was omitted; interactive push already queued", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
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
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    const pending_inspection = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const inspection_msg = try pending_inspection[0].run(allocator, io);
    const inspection_root_observer = inspection_msg.push_inspection_finished.root.?;
    _ = std.posix.system.close(inspection_root_observer.handle);
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const status = app.pages.changes.status.text();
    try std.testing.expectEqualStrings("warning: credential-bearing proxy was omitted; interactive push repository authority is invalid", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
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
    defer app.clearRemoteError(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = repo.oid }));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    const pending_inspection = ctx.takePendingTasks();
    try std.testing.expectEqual(@as(usize, 1), pending_inspection.len);
    const inspection_msg = try pending_inspection[0].run(allocator, io);
    const inspection_root_observer = inspection_msg.push_inspection_finished.root.?;
    _ = beginAcceptedTestAction(&app, .stage_file);
    try app.update(inspection_msg, &ctx);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const status = app.pages.changes.status.text();
    try std.testing.expectEqualStrings("warning: credential-bearing proxy was omitted; another git action is running", status);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
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
    defer app.clearRemoteError(allocator);
    try app.setRemoteErrorWithRetry(allocator, "failed", try retryTargetForTest(&app, allocator, .{ .oid = "not-current" }));
    var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("push retry unavailable: commit changed; reload and try again", app.pages.changes.status.text());
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
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
}

test "finishPushForeground stale and duplicate terminals preserve newer action owner" {
    const allocator = std.testing.allocator;
    var app: RemoteHarness = .{ .allocator = allocator };
    const repo_root = try installCurrentRepoForTest(&app, allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.clearPushForeground(allocator);
    defer action_lifecycle.testing.clear(&app.action_runtime);
    app.pages.changes.status.set("unchanged", .{});

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
    try std.testing.expectEqualStrings("unchanged", app.pages.changes.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.actionLifecycleView().isAccepted(current));
    try std.testing.expectEqualStrings("unchanged", app.pages.changes.status.text());
    try std.testing.expect(finishTestAction(&app, current, ""));
}

test "interactive push foreground terminals publish proxy warning once for both modes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        mode: git_ops.PushMode,
        outcome: chasen.ForegroundCommandOutcome,
        expected: []const u8,
    }{
        .{ .mode = .upstream, .outcome = .{ .exited = 0 }, .expected = "warning: credential-bearing proxy was omitted; pushed interactively: main -> origin/main" },
        .{ .mode = .set_upstream, .outcome = .{ .exited = 3 }, .expected = "warning: credential-bearing proxy was omitted; interactive push exited: 3" },
        .{ .mode = .upstream, .outcome = .{ .signaled = 2 }, .expected = "warning: credential-bearing proxy was omitted; interactive push signal: 2" },
        .{ .mode = .set_upstream, .outcome = .{ .stopped = 20 }, .expected = "warning: credential-bearing proxy was omitted; interactive push stopped and terminated: 20" },
        .{ .mode = .upstream, .outcome = .{ .failed = .{ .stage = .handoff, .error_name = "HANDOFF-CANARY" } }, .expected = "warning: credential-bearing proxy was omitted; interactive push handoff failed: HANDOFF-CANARY" },
        .{ .mode = .set_upstream, .outcome = .runtime_abandoned, .expected = "" },
        .{ .mode = .set_upstream, .outcome = .{ .failed = .{ .stage = .spawn, .error_name = "SPAWN-CANARY" } }, .expected = "warning: credential-bearing proxy was omitted; interactive push spawn failed: SPAWN-CANARY" },
        .{ .mode = .upstream, .outcome = .{ .failed = .{ .stage = .wait, .error_name = "WAIT-CANARY" } }, .expected = "warning: credential-bearing proxy was omitted; interactive push wait failed: WAIT-CANARY" },
    };

    for (cases, 0..) |case, index| {
        var app: RemoteHarness = .{ .allocator = allocator };
        _ = try installCurrentRepoForTest(&app, allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushForeground(allocator);
        defer action_lifecycle.testing.clear(&app.action_runtime);
        activateChanges(&app);
        const pending = beginAcceptedTestAction(&app, .push);
        try installForegroundForTest(&app, allocator, index + 1, pending, try retryTargetForTest(&app, allocator, .{ .mode = case.mode }));
        app.remote_workflow.push_retry.state.foreground.warnings.proxy_credentials_omitted = true;
        const foreground_root_observer = app.remote_workflow.push_retry.state.foreground.root;
        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };

        const completion = try app.remoteWorkflow().finishPushForeground(&ctx, .{
            .request_id = .{ .id = index + 1 },
            .outcome = case.outcome,
        });

        const status = app.pages.changes.status.text();
        try std.testing.expectEqual(@as(@TypeOf(completion.reload), if (case.outcome == .runtime_abandoned) .none else .source_and_aux), completion.reload);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
        try std.testing.expect(app.overlay.kind == .none);
        try std.testing.expectEqualStrings(case.expected, status);
        try std.testing.expectEqual(@as(usize, if (case.outcome == .runtime_abandoned) 0 else 1), std.mem.count(u8, status, "warning: credential-bearing proxy was omitted"));
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
        activateChanges(&app);
        const pending = beginAcceptedTestAction(&app, .push);
        try installForegroundForTest(&app, allocator, 41, pending, try retryTargetForTest(&app, allocator, .{}));
        const foreground_root_observer = app.remote_workflow.push_retry.state.foreground.root;
        app.pages.changes.status.set("replacement status", .{});

        app.remote_workflow.repositoryInvalidationPort(&app.overlay).invalidateBeforeRepositoryReplacement(allocator);
        try std.testing.expect(app.remote_workflow.push_retry.state == .foreground);
        try installActiveRepoForTest(&app, allocator, repo_b);

        var ctx: chasen.Ctx(RemoteHarness.Msg) = .{ ._allocator = allocator };
        try app.finishPushForeground(&ctx, .{
            .request_id = .{ .id = 41 },
            .outcome = .{ .exited = 0 },
        });

        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(!app.actionLifecycleView().hasPending());
        try std.testing.expectEqualStrings("replacement status", app.pages.changes.status.text());
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
