//! Owner-local tests for Repository coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_message = @import("../../message.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const page = @import("../../page.zig");
const page_link = @import("../../page_link.zig");
const repo_session = @import("../../repo_session.zig");
const repository_page = @import("../repository.zig");
const repository_coordinator = @import("coordinator.zig");
const repository_tasks = @import("tasks.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");

const RepositoryBranchTask = repository_tasks.BranchTask(app_message.Msg);
const RepositoryPathHistoryTask = repository_tasks.PathHistoryTask(app_message.Msg);
const RepositoryDocumentTask = repository_tasks.DocumentTask(app_message.Msg);
const RepositorySyntaxTask = repository_tasks.SyntaxTask(app_message.Msg);
const RepositoryChangeMapTask = repository_tasks.ChangeMapTask(app_message.Msg);

const RedrawPlan = struct {
    skip_requested: bool = false,

    fn requestSkip(self: *RedrawPlan) void {
        self.skip_requested = true;
    }

    fn resolvesToSkip(self: RedrawPlan) bool {
        return self.skip_requested;
    }
};

const TestApp = struct {
    allocator: ?std.mem.Allocator = null,
    active_page: page.Id = .repository,
    repo_session: repo_session.State = .{},
    pages: struct { repository: repository_page.RepositoryPageState = .{} } = .{},
    redraw_plan: RedrawPlan = .{},

    const Msg = app_message.Msg;

    fn controller(self: *TestApp) repository_coordinator.Controller {
        return .{
            .page_state = &self.pages.repository,
            .active_page = self.active_page,
            .repo = self.repo_session.view(),
            .body_size = .{ .width = 100, .height = 30 },
            .env_map = null,
        };
    }

    fn update(self: *TestApp, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .repository => |repository_msg| app_testing.updateRepository(self, ctx, repository_msg),
            else => unreachable,
        }
    }
};

const app_testing = struct {
    fn repositoryCoordinator(app: *TestApp) repository_coordinator.Controller {
        return app.controller();
    }

    fn updateRepository(app: *TestApp, ctx: *chasen.Ctx(TestApp.Msg), msg: repository_page.Msg) void {
        var outcome = app.controller().update(ctx, msg);
        defer outcome.deinit(ctx.allocator());
        if (outcome.redraw == .skip) app.redraw_plan.requestSkip();
    }
};

test "Repository drag auto-scroll coordinator transfers terminal only for active page" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{};
    defer app.pages.repository.deinit(allocator);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    const step: repository_page.Msg = .{ .mouse_source_auto_scroll_step = .{
        .direction = .down,
        .endpoint = .{ .col = 4, .row = 8 },
    } };

    var active = app.controller().update(&ctx, step);
    defer active.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.stale_owner, active.auto_scroll.?);
    try std.testing.expectEqual(repository_coordinator.Redraw.default, active.redraw);

    app.active_page = .compare;
    var inactive = app.controller().update(&ctx, step);
    defer inactive.deinit(allocator);
    try std.testing.expect(inactive.auto_scroll == null);
    try std.testing.expectEqual(repository_coordinator.Redraw.skip, inactive.redraw);
}

test "Repository branch App route runs owned task and preserves primary status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initializeRepositoryBranchAppRepoForTest(allocator, io, tmp.dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 3,
        },
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    try configureRepositoryBranchAppForTest(&app, allocator, root_path);
    app.pages.repository.status.set("Selected source range", .{});
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };

    _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const task: *RepositoryBranchTask = @ptrCast(@alignCast(queued[0].ctx));
    try std.testing.expectEqual(page.RequestIdentity{
        .origin = .repository,
        .repo_epoch = 3,
        .activation_id = app.pages.repository.activation_id,
    }, task.request.identity);
    try std.testing.expect(task.request.root.identity.eql(app.repo_session.view().activeIdentity().?));
    try std.testing.expectEqualStrings(root_path, task.request.root_path);

    const message = queued[0].run(queued[0].ctx, allocator, io);
    try app.update(message, &ctx);

    try std.testing.expectEqualStrings("main", app.pages.repository.branch.snapshot.status.branchName().?);
    try std.testing.expect(app.pages.repository.branch.freshness == .fresh);
    try std.testing.expect(app.pages.repository.branch.pending == null);
    try std.testing.expectEqualStrings("Selected source range", app.pages.repository.status.text());
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}

test "Repository path history App route runs one task and preserves primary status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initializeRepositoryBranchAppRepoForTest(allocator, io, tmp.dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{ .repo_epoch = 3 },
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    try configureRepositoryBranchAppForTest(&app, allocator, root_path);
    app.pages.repository.branch.needs_revalidation = false;
    app.pages.repository.selected_path = "tracked.txt";
    app.pages.repository.manifest_revision = 7;
    app.pages.repository.path_history.invalidate(allocator, true);
    app.pages.repository.status.set("Selected source range", .{});
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };

    _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const task: *RepositoryPathHistoryTask = @ptrCast(@alignCast(queued[0].ctx));
    try std.testing.expectEqualStrings("tracked.txt", task.request.path);
    try std.testing.expectEqual(@as(u64, 7), task.request.manifest_revision);
    try std.testing.expect(task.request.root.identity.eql(app.repo_session.view().activeIdentity().?));

    const message = queued[0].run(queued[0].ctx, allocator, io);
    try app.update(message, &ctx);

    const presentation = app.pages.repository.sourceHeaderPresentation().?;
    try std.testing.expect(presentation.commit_fact == .committed);
    try std.testing.expect(app.pages.repository.path_history.terminal == .known);
    try std.testing.expectEqualStrings("Selected source range", app.pages.repository.status.text());
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}

test "Repository branch App start failures close request owners and stay branch local" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    // The first request allocation fails before a generation is armed.
    {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{ .repo_epoch = 1 },
        };
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        try configureRepositoryBranchAppForTest(&app, allocator, root_path);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = failing.allocator(), ._io = io };

        _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);

        try std.testing.expect(app.pages.repository.branch.pending == null);
        try std.testing.expectEqual(@as(u64, 0), app.pages.repository.branch.generation);
        try std.testing.expect(app.pages.repository.branch.freshness.failed == .preparation_failed);
        try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
    }

    // Request preparation succeeds, then task allocation fails. The exact
    // armed generation is terminalized and the unconsumed request defer closes
    // both path and duplicated descriptor.
    {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{ .repo_epoch = 2 },
        };
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        try configureRepositoryBranchAppForTest(&app, allocator, root_path);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = failing.allocator(), ._io = io };

        _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);

        try std.testing.expect(app.pages.repository.branch.pending == null);
        try std.testing.expectEqual(@as(u64, 1), app.pages.repository.branch.generation);
        try std.testing.expect(app.pages.repository.branch.freshness.failed == .start_failed);
        try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
    }

    // A full Chasen task queue rejects synchronously after the task captured
    // the request. The coordinator dismantles that concrete task and closes
    // only its exact generation.
    {
        const DummyTask = struct {
            fn run(_: std.mem.Allocator, _: std.Io) TestApp.Msg {
                return .quit;
            }
            fn failed(_: chasen.TaskFailure) TestApp.Msg {
                return .quit;
            }
        };
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{ .repo_epoch = 3 },
        };
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        try configureRepositoryBranchAppForTest(&app, allocator, root_path);
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
        for (0..16) |_| try ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

        _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);

        try std.testing.expect(app.pages.repository.branch.pending == null);
        try std.testing.expectEqual(@as(u64, 1), app.pages.repository.branch.generation);
        try std.testing.expect(app.pages.repository.branch.freshness.failed == .start_failed);
        try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
        try std.testing.expectEqual(@as(usize, 16), ctx.takePendingTasks().len);
    }
}

test "Repository branch App runtime terminals preserve diagnostic ownership" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    // A runtime start failure is delivered through the normal App route.
    {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{ .repo_epoch = 4 },
        };
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        try configureRepositoryBranchAppForTest(&app, allocator, root_path);
        app.pages.repository.status.set("Copy failed", .{});
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
        _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);
        const queued = ctx.takePendingTasksWith();
        try std.testing.expectEqual(@as(usize, 1), queued.len);

        const message = queued[0].failed(queued[0].ctx, .{ .start_failed = "SystemResources" }, allocator);
        try app.update(message, &ctx);

        try std.testing.expect(app.pages.repository.branch.freshness.failed == .start_failed);
        try std.testing.expectEqualStrings("Copy failed", app.pages.repository.status.text());
        try std.testing.expect(!ctx.redrawWasSuppressed());
    }

    // Runtime unwind consumes the captured task request, then disposes the
    // returned completion without delivering it. The pending scalar is inert
    // because App teardown follows; no owned payload remains behind it.
    {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{ .repo_epoch = 5 },
        };
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        try configureRepositoryBranchAppForTest(&app, allocator, root_path);
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
        _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);
        const queued = ctx.takePendingTasksWith();
        try std.testing.expectEqual(@as(usize, 1), queued.len);

        var message = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);

        try std.testing.expect(app.pages.repository.branch.pending != null);
        try std.testing.expect(app.pages.repository.branch.freshness == .validating);
    }

    // App-level undelivered routing owns loaded arenas as well as failure-only
    // messages; std.testing.allocator verifies the complete cleanup terminal.
    var undelivered = TestApp.Msg{ .repository = .{ .branch_finished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 9, .activation_id = 1 },
        .root_identity = .{ .device = 2, .inode = 3 },
        .generation = 4,
        .result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .branch = "undelivered" }) },
    } } };
    undelivered.deinitUndelivered(allocator);
}

test "Repository page header unchanged branch completion redraws fresh terminal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{ .repo_epoch = 6 },
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    try configureRepositoryBranchAppForTest(&app, allocator, root_path);

    var request = try app.pages.repository.prepareBranchRequest(allocator, root_path, &app.repo_session.repo_state.root.?);
    defer request.deinit(allocator);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
    updateRepositoryForTest(&app, &ctx, .{ .branch_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation + 1,
        .result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .branch = "stale" }) },
    } });
    try std.testing.expectEqual(request.generation, app.pages.repository.branch.pending.?.generation);
    try std.testing.expect(app.pages.repository.branch.snapshot.identity == null);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    updateRepositoryForTest(&app, &ctx, .{ .branch_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .branch = "main" }) },
    } });
    try std.testing.expectEqualStrings("main", app.pages.repository.branch.snapshot.status.branchName().?);
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());

    app.pages.repository.requestReload(true, .manual);
    app.pages.repository.needs_revalidation = false;
    var unchanged_request = try app.pages.repository.prepareBranchRequest(allocator, root_path, &app.repo_session.repo_state.root.?);
    defer unchanged_request.deinit(allocator);
    app.redraw_plan = .{};
    updateRepositoryForTest(&app, &ctx, .{ .branch_finished = .{
        .identity = unchanged_request.identity,
        .root_identity = unchanged_request.root.identity,
        .generation = unchanged_request.generation,
        .result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .branch = "main" }) },
    } });
    try std.testing.expect(app.pages.repository.branch.freshness == .fresh);
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());

    app.pages.repository.requestReload(true, .manual);
    app.pages.repository.needs_revalidation = false;
    var inactive_request = try app.pages.repository.prepareBranchRequest(allocator, root_path, &app.repo_session.repo_state.root.?);
    defer inactive_request.deinit(allocator);
    app.pages.repository.deactivate();
    app.active_page = .compare;
    app.redraw_plan = .{};
    updateRepositoryForTest(&app, &ctx, .{ .branch_finished = .{
        .identity = inactive_request.identity,
        .root_identity = inactive_request.root.identity,
        .generation = inactive_request.generation,
        .result = .{ .loaded = try branchStatusBundleForTest(allocator, .{ .branch = "inactive" }) },
    } });
    try std.testing.expectEqualStrings("inactive", app.pages.repository.branch.snapshot.status.branchName().?);
    try std.testing.expect(app.pages.repository.branch.freshness == .validating);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "repository transition missing document capability closes incoming owner" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 2,
            .repo_epoch = 3,
            .root_identity = .{ .device = 5, .inode = 8 },
            .manifest_revision = 13,
            .selected_path = "main.zig",
            .needs_document_revalidation = true,
        } },
    };
    defer app.pages.repository.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.pages.repository.repo_epoch,
        app.pages.repository.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    app.pages.repository.acceptIncoming(allocator, &incoming);
    try std.testing.expect(app.pages.repository.incoming.advanceToDocument(
        app.pages.repository.manifest_revision,
    ));
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);

    const unavailable = app.pages.repository.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expect(!app.pages.repository.needs_document_revalidation);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "repository transition ordinary document capability loss preserves retry" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 2,
            .repo_epoch = 3,
            .root_identity = .{ .device = 5, .inode = 8 },
            .manifest_revision = 13,
            .selected_path = "main.zig",
            .needs_document_revalidation = true,
        } },
    };
    app.pages.repository.status.set("retained diagnostic", .{});
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    _ = try app_testing.repositoryCoordinator(&app).startPending(&ctx);

    try std.testing.expect(app.pages.repository.needs_document_revalidation);
    try std.testing.expectEqualStrings("retained diagnostic", app.pages.repository.status.text());
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "repository syntax task allocation and spawn failures release owners and remain retryable" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    const source_bytes = try allocator.dupe(u8, "const value = 1;\n");
    var source_transferred = false;
    var source_value = @import("../../../repository/source.zig").Document.initOwned(
        allocator,
        source_bytes,
        .init(source_bytes),
    ) catch |err| {
        allocator.free(source_bytes);
        return err;
    };
    errdefer if (!source_transferred) source_value.deinit(allocator);
    const displayed_path = try allocator.dupe(u8, "main.zig");
    errdefer if (!source_transferred) allocator.free(displayed_path);
    app.pages.repository = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = app.repo_session.repo_state.root.?.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .load_state = .loaded,
        .selected_path = "main.zig",
        .needs_syntax_request = true,
        .displayed_document = .{
            .path = displayed_path,
            .manifest_revision = 5,
            .source_revision = 6,
            .authority = .accepted,
            .value = .{ .source = source_value },
        },
    };
    source_transferred = true;

    // prepareSyntaxRequest allocates the path first; fail the following task
    // object allocation and let the unconsumed request defer release path/root.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var allocation_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    _ = try app_testing.repositoryCoordinator(&app).startPending(&allocation_ctx);
    try std.testing.expect(app.pages.repository.wantsSyntaxRequest());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestApp.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) TestApp.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    _ = try app_testing.repositoryCoordinator(&app).startPending(&spawn_ctx);
    try std.testing.expect(app.pages.repository.wantsSyntaxRequest());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);

    var retry_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
    _ = try app_testing.repositoryCoordinator(&app).startPending(&retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "repository change map task allocation and spawn failures release owners and remain retryable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    const source_bytes = try allocator.dupe(u8, "const value = 1;\n");
    var source_transferred = false;
    var source_value = @import("../../../repository/source.zig").Document.initOwned(
        allocator,
        source_bytes,
        .init(source_bytes),
    ) catch |err| {
        allocator.free(source_bytes);
        return err;
    };
    errdefer if (!source_transferred) source_value.deinit(allocator);
    const displayed_path = try allocator.dupe(u8, "main.zig");
    errdefer if (!source_transferred) allocator.free(displayed_path);
    app.pages.repository = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = app.repo_session.repo_state.root.?.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .load_state = .loaded,
        .selected_path = "main.zig",
        .needs_change_map_request = true,
        .displayed_document = .{
            .path = displayed_path,
            .manifest_revision = 5,
            .source_revision = 6,
            .authority = .accepted,
            .value = .{ .source = source_value },
            .change_decoration = .eligible,
        },
    };
    source_transferred = true;

    // Request preparation owns path/temp-base/root. Fail the following task
    // allocation and prove the request defer returns all three owners.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    var allocation_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    _ = try app_testing.repositoryCoordinator(&app).startPending(&allocation_ctx);
    try std.testing.expect(app.pages.repository.wantsChangeMapRequest());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestApp.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) TestApp.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    _ = try app_testing.repositoryCoordinator(&app).startPending(&spawn_ctx);
    try std.testing.expect(app.pages.repository.wantsChangeMapRequest());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);

    var retry_ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator, ._io = io };
    _ = try app_testing.repositoryCoordinator(&app).startPending(&retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
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

fn configureRepositoryBranchAppForTest(
    app: *TestApp,
    allocator: std.mem.Allocator,
    root_path: []const u8,
) !void {
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, root_path);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    app.pages.repository.activate(app.repo_session.repo_epoch, app.repo_session.view().activeIdentity());
    // These integration tests isolate the auxiliary member. The manifest
    // coordinator has its own start/apply suite and must not add an unrelated
    // task to the branch assertions below.
    app.pages.repository.needs_revalidation = false;
}

fn updateRepositoryForTest(
    app: *TestApp,
    ctx: *chasen.Ctx(TestApp.Msg),
    msg: repository_page.Msg,
) void {
    app_testing.updateRepository(app, ctx, msg);
}

fn initializeRepositoryBranchAppRepoForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
) !void {
    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, dir);
    try dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "tracked.txt" }, dir);
    try runAppTestGit(allocator, io, &.{
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "base",
    }, dir);
}

fn runAppTestGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
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

fn clearPendingRepositoryTasks(ctx: *chasen.Ctx(TestApp.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}
