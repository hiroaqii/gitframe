//! Root integration tests for remote workflows and shell effects.

const std = @import("std");
const chasen = @import("chasen");

const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_push_retry = @import("../push_retry.zig");
const app_state = @import("../state.zig");
const app_test_support = @import("../test_support.zig");
const effect_origin = @import("../effect_origin.zig");
const page = @import("../page.zig");
const repo_session = @import("../repo_session.zig");
const review_page = @import("../pages/review.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const review_selection_model = @import("../diff_surface/selection.zig");
const review_reload = @import("../pages/review/reload.zig");
const review_navigation = @import("../pages/review/navigation.zig");
const workflow_remote = @import("../workflow/remote.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_source = @import("../../diff/source.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_ops = @import("../git_ops.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");

const App = app_mod.App;
const app_testing = app_mod.testing;

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
    return app_testing.installAcceptedActionFixture(app, kind);
}

fn mutationFenceRepoTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !App {
    var app: App = .{
        .allocator = allocator,
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
    };
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    app_testing.activateReview(&app);
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
    app.pages.review.activation.deactivate();
    app_testing.activateReview(app);
}

fn installInteractivePushRetryForFenceTest(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    oid: []const u8,
) !void {
    try app_testing.setPushErrorWithRetry(app, allocator, "failed", .{
        .mode = .set_upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, oid),
    }, true);
}

fn installTestActionCursor(
    app: *App,
    allocator: std.mem.Allocator,
    kind: review_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    try app_testing.installActionCursor(
        app,
        allocator,
        kind,
        path_key,
        action_generation,
        test_action_root_identity,
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

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    app.pages.review.search.input = .{};
    @memcpy(app.pages.review.search.input.buffer[0..query.len], query);
    app.pages.review.search.input.len = query.len;
    app.pages.review.search.input.cursor = query.len;
}

fn installPushCredentialPromptForTest(app: *App, allocator: std.mem.Allocator) !void {
    var target = app_state.PushRetryTarget.empty();
    var target_owned = true;
    defer if (target_owned) target.deinit(allocator);
    target.repo_root = try allocator.dupe(u8, "/repo");
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
test "Review mutation read fence follows interactive foreground queue and terminal" {
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
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app_testing.clearPushError(&app, allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_rejection =
            app.pages.review.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        _ = try ctx.terminal().runForegroundCommand(.{
            .argv = &.{"true"},
            .cwd = repo.repo_root,
            .finished = DummyForeground.done,
        });

        try app_testing.runInteractivePush(&app, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

        try std.testing.expect(!app_testing.actionView(&app).hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expect(
            app.pages.review.repository_read_authority.epoch.eql(
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
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app_testing.clearPushError(&app, allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_launch =
            app.pages.review.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app_testing.runInteractivePush(&app, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.review.repository_read_authority.mayStartRepositoryRead();
        const epoch_advanced =
            app.pages.review.repository_read_authority.epoch.eql(
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
        try std.testing.expect(!app_testing.actionView(&app).hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
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
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app_testing.clearPushError(&app, allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app_testing.runInteractivePush(&app, &ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.review.repository_read_authority.mayStartRepositoryRead();
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
        try std.testing.expect(!app_testing.actionView(&app).hasPending());
        try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
        try std.testing.expectEqualStrings(roots.a, app_testing.repoView(&app).activeRoot().?);
    }
}

test "Review mutation read fence follows credentialed push queue acceptance" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.pages.review.deinit(allocator);
    defer app_testing.clearPushError(&app, allocator);
    app_testing.activateReview(&app);
    try installPushCredentialPromptForTest(&app, allocator);
    const epoch_before_launch = app.pages.review.repository_read_authority.epoch;

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    try app_testing.submitPushCredentials(&app, &ctx);
    const owner = app_testing.actionView(&app).acceptedPending() orelse return error.ExpectedPendingAction;
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    const epoch_advanced =
        app.pages.review.repository_read_authority.epoch.eql(epoch_before_launch.next());

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const completion = queued[0].failed(
        queued[0].ctx,
        .runtime_abandoned,
        allocator,
    );
    try app.update(completion, &ctx);

    try std.testing.expectEqual(app_actions.ActionKind.push, owner.kind);
    try std.testing.expect(fence_closed);
    try std.testing.expect(epoch_advanced);
    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    // A valid remote request owns the confirmation-exclusivity boundary even
    // when its first allocation fails. Local state must not survive only
    // because the typed success outcome could not be returned.
    var failure_app: App = .{
        .allocator = allocator,
        .active_page = .review,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer failure_app.pages.review.branch_status.deinit();
    defer failure_app.pages.review.git_status.deinit();
    defer failure_app.remote_workflow.deinit(allocator);
    defer if (failure_app.local_workflow.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
    var branch = try branchStatusBundleForRemoteRootTest(
        allocator,
        "abc123",
        "feature",
        "origin/main",
    );
    try failure_app.pages.review.branch_status.replace("/repo", &branch);
    _ = failure_app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    failure_app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "src/app.zig"),
    };
    failure_app.overlay.openDiscardFile();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };

    try std.testing.expectError(
        error.OutOfMemory,
        app_testing.requestRemotePush(&failure_app, &failing_ctx),
    );
    try std.testing.expect(failure_app.local_workflow.discard_confirmation == null);
    try std.testing.expect(!failure_app.overlay.isDiscardFile());
    try std.testing.expect(failure_app.remote_workflow.push_confirmation == null);

    var status = try git_status.StatusBundle.parseOwned(allocator, "");
    try failure_app.pages.review.git_status.replace("/repo", &status);
    _ = failure_app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    failure_app.local_workflow.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
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
        app_testing.requestRemoteBranchSwitch(&failure_app, &saturated_ctx),
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

    app_testing.copySourceSelection(&app, &ctx, "selected source");

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

    app_testing.copySourceHeaderPath(&app, &ctx, path);

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

    app_testing.copySourceSelection(&app, &ctx, app.pages.repository.completed_selection.?.text);

    try std.testing.expectEqual(@as(u8, 4), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(@as(usize, 0), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("selected source", app.pages.repository.completed_selection.?.text);
    try std.testing.expectEqualStrings("clipboard copy already queued", app.pages.repository.status.text());
}

test "copyPopup queues push error message text" {
    var app: App = .{
        .remote_workflow = .{
            .push_error_message = try std.testing.allocator.dupe(u8, "  fatal\nline two  "),
        },
    };
    defer std.testing.allocator.free(app.remote_workflow.push_error_message.?);
    defer app.shell_effects_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openPushError();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app_testing.copyPopup(&app, &ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("  fatal\nline two  ", entry.text);
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.Msg.clipboardFinished), entry.finished);
    const state = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(app.overlay.push_error_instance_id, state.origin.shell_surface.instance_id);
}

test "copyPopup reports empty target outside copyable popup" {
    var app: App = .{};
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app_testing.copyPopup(&app, &ctx);

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

    app_testing.copyCommitMessage(&app, &ctx);

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

    app_testing.copyCommitMessage(&app, &ctx);

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

    app_testing.copyCommitMessage(&app, &ctx);

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

    app_testing.copyCommitMessage(&app, &ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());

    app.local_workflow.commit_panel.open(.commit);
    app_testing.copyCommitMessage(&app, &ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());
}

test "finishSwitchBranch success clears repo-local review state and reloads matching repo" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app_testing.activateReview(&app);
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);
    defer app_testing.clearActionCursor(&app, allocator);
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);

    try app.pages.review.reviewed_store.set(allocator, app_testing.repoView(&app).activeRoot(), app_test_support.files_two[0], true);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", testSessionHunkMarkKey(1, 0));
    try installTestActionCursor(&app, allocator, .file, "a", 99);
    setDiffSearchQuery(&app, "needle");

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app_testing.finishSwitchBranch(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(!try app.pages.review.reviewed_store.containsFile(allocator, app_testing.repoView(&app).activeRoot(), app_test_support.files_two[0]));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.search.query.len);
    try std.testing.expectEqualStrings("switched branch: main -> feature", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
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
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);

    try app.pages.review.reviewed_store.set(allocator, "/repo", app_test_support.files_two[0], true);
    try app.pages.review.reviewed_store.set(allocator, "/other", app_test_support.files_two[1], true);
    const old_key = testSessionHunkMarkKey(1, 0);
    const new_key = testSessionHunkMarkKey(1, 1);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", old_key);
    try app.pages.review.staged_hunks.addExact(allocator, "/other", "b", new_key);

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app_testing.finishSwitchBranch(&app, &ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(!try app.pages.review.reviewed_store.containsFile(allocator, "/repo", app_test_support.files_two[0]));
    try std.testing.expect(try app.pages.review.reviewed_store.containsFile(allocator, "/other", app_test_support.files_two[1]));
    try std.testing.expect(!app.pages.review.staged_hunks.containsExact("/repo", "a", old_key));
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/other", "b", new_key));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("switched branch: /repo", app.pages.review.status.text());
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

    try app_testing.finishPush(&app, &ctx, .{
        .pending = pending,
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .ok,
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("pushed: /repo", app.pages.review.status.text());
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

    try app_testing.finishPull(&app, &ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .ok,
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("pulled: /repo", app.pages.review.status.text());
}

test "finishPull reloads matching active repo after up-to-date success" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app_testing.activateReview(&app);
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app_testing.finishPull(&app, &ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .ok_static = "nothing to pull" },
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("nothing to pull", app.pages.review.status.text());
}

test "finishPull reloads matching active repo after failure" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app_testing.activateReview(&app);
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app_testing.finishPull(&app, &ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .failed_static = "remote unavailable" },
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("pull failed: remote unavailable", app.pages.review.status.text());
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

    try app_testing.finishFetch(&app, &ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .ok,
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("fetched: /repo", app.pages.review.status.text());
}

test "finishFetch reloads matching active repo after failure" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app_testing.activateReview(&app);
    const pending = beginAcceptedTestAction(&app, .fetch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app_testing.finishFetch(&app, &ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .{ .failed_static = "remote unavailable" },
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("fetch failed: remote unavailable", app.pages.review.status.text());
}

test "repository supersession invalidates an in-flight push inspection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    app_testing.activateReview(&app);
    try app_testing.setPushErrorWithRetry(&app, allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app_testing.runInteractivePush(&app, &ctx);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqualStrings(roots.b, app_testing.repoView(&app).activeRoot().?);
    try std.testing.expect(app.remote_workflow.push_error_message == null);
}

test "direct root quit remains allowed while push inspection is running" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app_testing.clearPushError(&app, allocator);
    try app_testing.setPushErrorWithRetry(&app, allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app_testing.runInteractivePush(&app, &ctx);
    try app.update(.quit, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(app.remote_workflow.push_retry.state == .inspecting);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push inspection surface blocks page switching until canceled" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app_testing.clearPushError(&app, allocator);
    app_testing.activateReview(&app);
    try app_testing.setPushErrorWithRetry(&app, allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app_testing.runInteractivePush(&app, &ctx);
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("close push error before switching pages", app.status.text());
    app_testing.clearPushError(&app, allocator);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);

    app.status.clear();
    app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 41 },
        .origin = .{
            .page_id = .review,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.review.activation.next_activation_id,
        },
    };
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("finish foreground command before switching pages", app.status.text());
    app.shell_effects_state.editor_foreground = null;

    app.status.clear();
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 42 },
        .pending = .{ .generation = 99, .kind = .push },
        .origin = .{
            .page_id = .review,
            .repo_epoch = app.repo_session.repo_epoch,
            .activation_id = app.pages.review.activation.next_activation_id,
        },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("finish foreground command before switching pages", app.status.text());
}

test "inactive Review accepts push inspection diagnostic without redraw" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app_testing.clearPushError(&app, allocator);
    app_testing.activateReview(&app);
    try app_testing.setPushErrorWithRetry(&app, allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app_testing.runInteractivePush(&app, &ctx);
    app.active_page = .repository;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.remote_workflow.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("could not verify push retry target", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "finishPushForeground reloads matching active repo after failure" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app_testing.activateReview(&app);
    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 9 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app_testing.finishPushForeground(&app, &ctx, .{
        .request_id = .{ .id = 9 },
        .outcome = .{ .exited = 1 },
    });

    try std.testing.expect(!app_testing.actionView(&app).hasPending());
    try std.testing.expect(app.remote_workflow.push_retry.state == .idle);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("interactive push exited: 1", app.pages.review.status.text());
}

test "inactive Review foreground completions retain diagnostics without effects" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 3,
        },
    };
    const pending = beginAcceptedTestAction(&app, .push);
    app.remote_workflow.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 7 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = 3, .activation_id = 0 },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app_testing.finishPushForeground(&app, &ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 1 },
    });

    try std.testing.expectEqualStrings("interactive push exited for /repo: 1", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 8 },
        .origin = .{ .page_id = .review, .repo_epoch = 3, .activation_id = 0 },
    };
    try app_testing.finishEditorCommand(&app, &ctx, .{
        .request_id = .{ .id = 8 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expectEqualStrings("editor closed", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    // An exact completion from the active Review instance is the only editor
    // terminal that bridges into the Review read owner.
    var repos = try TestRepoPair.init();
    defer repos.deinit();
    var active_app = try mutationFenceRepoTestApp(allocator, repos.a);
    defer active_app.pages.review.deinit(allocator);
    defer active_app.repo_session.repo_state.deinit(allocator);
    active_app.shell_effects_state.editor_foreground = .{
        .request_id = .{ .id = 9 },
        .origin = .{
            .page_id = .review,
            .repo_epoch = active_app.repo_session.repo_epoch,
            .activation_id = active_app.pages.review.activation.next_activation_id,
        },
    };
    var active_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&active_ctx, allocator);

    try app_testing.finishEditorCommand(&active_app, &active_ctx, .{
        .request_id = .{ .id = 9 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(active_app.shell_effects_state.editor_foreground == null);
    try std.testing.expectEqualStrings("editor closed", active_app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 3), active_ctx._pending_tasks_with_len);
}
