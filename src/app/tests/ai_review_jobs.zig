const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_message = @import("../message.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");
const committed = @import("../../committed_review.zig");
const git_command = @import("../../git/command.zig");
const git_review = @import("../../git/committed_review.zig");
const job = @import("../../ai_review/job.zig");
const codex = @import("../../ai_review/adapters/codex/adapter.zig");
const pipeline = @import("../../ai_review/runner.zig");
const root_capability = @import("../../repo/root_capability.zig");
const store_service = @import("../../ai_review/store_service.zig");

const App = app_mod.App;

const PipelineFixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    repo: std.Io.Dir,
    repo_path: [:0]u8,
    store_path: [:0]u8,
    executable: []u8,
    root: root_capability.RootCapability,
    store: store_service.ConfiguredStore,
    target: committed.CommittedReviewTarget,

    fn init(allocator: std.mem.Allocator, io: std.Io) !PipelineFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .fromMode(0o700));
        try tmp.dir.createDir(io, "store", .fromMode(0o700));
        var repo = try tmp.dir.openDir(io, "repo", .{});
        errdefer repo.close(io);

        try runCommand(allocator, io, repo, &.{ "git", "init", "--initial-branch=main" });
        try repo.writeFile(io, .{ .sub_path = "sample.txt", .data = "base\n" });
        try runCommand(allocator, io, repo, &.{ "git", "add", "sample.txt" });
        try runCommand(allocator, io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
        try runCommand(allocator, io, repo, &.{ "git", "branch", "review-base", "HEAD" });
        try repo.writeFile(io, .{ .sub_path = "sample.txt", .data = "base\nhead\n" });
        try runCommand(allocator, io, repo, &.{ "git", "add", "sample.txt" });
        try runCommand(allocator, io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });

        const script =
            \\#!/bin/sh
            \\if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
            \\  printf '%s\n' 'codex-cli 999.0'
            \\  exit 0
            \\fi
            \\/bin/cat >/dev/null
            \\printf '%s\n' \
            \\  '{"type":"thread.started","thread_id":"fake"}' \
            \\  '{"type":"turn.started"}' \
            \\  '{"type":"item.completed","item":{"type":"agent_message","text":"{\"schema_version\":1,\"units\":[{\"ordinal\":1,\"candidate\":{\"findings\":[]}}]}"}}' \
            \\  '{"type":"turn.completed"}'
        ;
        try tmp.dir.writeFile(io, .{ .sub_path = "codex-fake", .data = script });
        const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root_path);
        const executable = try std.fs.path.join(allocator, &.{ root_path, "codex-fake" });
        errdefer allocator.free(executable);
        try runCommand(allocator, io, tmp.dir, &.{ "/bin/chmod", "0700", executable });

        const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
        errdefer allocator.free(repo_path);
        const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
        errdefer allocator.free(store_path);
        var root = try root_capability.RootCapability.openCanonical(repo_path);
        errdefer root.deinit();
        var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
        defer environment.deinit();
        const resolved = try git_review.resolveTarget(allocator, io, .{
            .cwd = root.dir(),
            .environment = &environment,
        }, .{
            .source_kind = .branch_range,
            .base = "refs/heads/review-base",
            .head = "refs/heads/main",
        });
        const target = switch (resolved) {
            .target => |value| value,
            .failure => return error.TargetResolutionFailed,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .tmp = tmp,
            .repo = repo,
            .repo_path = repo_path,
            .store_path = store_path,
            .executable = executable,
            .root = root,
            .store = try store_service.ConfiguredStore.initConfigured(allocator, store_path),
            .target = target,
        };
    }

    fn deinit(self: *PipelineFixture) void {
        self.store.deinit(self.allocator);
        self.root.deinit();
        self.allocator.free(self.executable);
        self.allocator.free(self.store_path);
        self.allocator.free(self.repo_path);
        self.repo.close(self.io);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn request(self: *PipelineFixture) !pipeline.Request {
        return self.requestWithExecutable(self.executable);
    }

    fn requestWithExecutable(self: *PipelineFixture, executable: []const u8) !pipeline.Request {
        return pipeline.Request.init(
            self.allocator,
            self.root,
            null,
            &self.store,
            self.repo_path,
            self.target,
            null,
            .{ .codex = try codex.Request.init(self.allocator, executable, null) },
            "bounded context",
        );
    }

    fn scope(self: *const PipelineFixture) job.Scope {
        return .{ .repository = self.root.identity, .target = self.target };
    }

    fn storeEmpty(self: *PipelineFixture) !bool {
        var directory = try self.tmp.dir.openDir(self.io, "store", .{ .iterate = true });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        return try iterator.next(self.io) == null;
    }
};

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TestCommandFailed;
}

fn runOnlyTask(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator, io: std.Io) !App.Msg {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    return entries[0].run(entries[0].ctx, allocator, io);
}

fn failOnlyTask(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator, failure: chasen.TaskFailure) !App.Msg {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    return entries[0].failed(entries[0].ctx, failure, allocator);
}

fn inertTask(_: std.mem.Allocator, _: std.Io) App.Msg {
    return .focus_lost;
}

fn inertTaskFailed(_: chasen.TaskFailure) App.Msg {
    return .focus_lost;
}

fn fillTaskQueue(ctx: *chasen.Ctx(App.Msg)) usize {
    var count: usize = 0;
    while (count < 128) : (count += 1) {
        ctx.task().spawn(.{ .run = inertTask, .failed = inertTaskFailed }) catch break;
    }
    return count;
}

fn beginAcceptedInertAction(app: *App) app_actions.PendingAction {
    const lifecycle: action_lifecycle.Controller = .{
        .runtime = &app.action_runtime,
        .fence = undefined,
    };
    const prepared = lifecycle.prepare(.assist_commit_message);
    return lifecycle.acceptSpawn(std.testing.allocator, prepared).pending;
}

test "AI review App uses two one-shot tasks and exposes publishing before exact terminal" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
    const review_message = try runOnlyTask(&tc.ctx, allocator, io);
    try app.update(review_message, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
    try std.testing.expect(!tc.redrawSuppressed());
    try std.testing.expect(try fixture.storeEmpty());
    app.repo_session.repo_epoch = 99;
    try std.testing.expect(app.ai_review_jobs.find(key).?.scope.repository.eql(fixture.root.identity));

    var duplicate_result = pipeline.review(allocator, io, try fixture.request(), .{});
    try std.testing.expect(duplicate_result == .ready);
    const duplicate_ready = duplicate_result.ready;
    duplicate_result = .{ .terminal = .{ .outcome = .canceled } };
    try app.update(App.Msg.aiReviewJob(.{ .review_finished = .{
        .key = key,
        .outcome = .{ .pipeline = .{ .ready = duplicate_ready } },
    } }), &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
    try std.testing.expect(try fixture.storeEmpty());

    const publication_message = try runOnlyTask(&tc.ctx, allocator, io);
    try app.update(publication_message, &tc.ctx);
    const record = app.ai_review_jobs.find(key).?;
    try std.testing.expect(record.phase == .terminal);
    try std.testing.expect(record.phase.terminal == .pipeline);
    try std.testing.expect(record.phase.terminal.pipeline.outcome == .published);
    try std.testing.expectEqual(@as(u32, 0), record.phase.terminal.pipeline.outcome.published.finding_count);

    const duplicate: App.Msg = App.Msg.aiReviewJob(.{ .publication_finished = .{
        .key = key,
        .outcome = .{ .terminal = .{ .outcome = .no_changes } },
    } });
    try app.update(duplicate, &tc.ctx);
    try std.testing.expect(record.phase.terminal.pipeline.outcome == .published);
    try app.update(.quit, &tc.ctx);
    try std.testing.expect(tc.ctx.shouldQuit());
}

test "AI review App rejects stale ReadyToPublish and honors cancellation at the adoption gate" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();

    {
        var app: App = .{ .allocator = allocator };
        defer app.ai_review_jobs.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = .{};
        defer tc.resetTransient();
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
        var stale = try runOnlyTask(&tc.ctx, allocator, io);
        stale.ai_review_job.review_finished.key.generation +%= 1;
        try app.update(stale, &tc.ctx);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
        try std.testing.expect(try fixture.storeEmpty());
    }

    {
        var app: App = .{ .allocator = allocator };
        defer app.ai_review_jobs.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = .{};
        defer tc.resetTransient();
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
        const ready = try runOnlyTask(&tc.ctx, allocator, io);
        try std.testing.expect(app.cancelAiReview(key));
        try app.update(ready, &tc.ctx);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase.terminal.pipeline.outcome == .canceled);
        try std.testing.expectEqual(@as(usize, 0), tc.ctx.takePendingTasksWith().len);
        try std.testing.expect(try fixture.storeEmpty());
    }
}

test "AI review App maps immediate review and publication queue failures to typed terminals" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();

    {
        var app: App = .{ .allocator = allocator };
        defer app.ai_review_jobs.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = .{};
        defer tc.resetTransient();
        try std.testing.expect(fillTaskQueue(&tc.ctx) > 0);
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
        try std.testing.expectEqual(job.StartFailure.review_task_start_failed, app.ai_review_jobs.find(key).?.phase.terminal.start_failed);
        _ = tc.ctx.takePendingTasks();
        try std.testing.expect(try fixture.storeEmpty());
    }

    {
        var app: App = .{ .allocator = allocator };
        defer app.ai_review_jobs.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = .{};
        defer tc.resetTransient();
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
        const ready = try runOnlyTask(&tc.ctx, allocator, io);
        try std.testing.expect(fillTaskQueue(&tc.ctx) > 0);
        try app.update(ready, &tc.ctx);
        try std.testing.expectEqual(job.StartFailure.publication_task_start_failed, app.ai_review_jobs.find(key).?.phase.terminal.start_failed);
        _ = tc.ctx.takePendingTasks();
        try std.testing.expect(try fixture.storeEmpty());
    }
}

test "AI review publication context allocation failure is terminal before Store prepare" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var normal: chasen.testing.TestCtx(App.Msg) = .{};
    defer normal.resetTransient();

    const key = app.enqueueAiReview(&normal.ctx, fixture.scope(), try fixture.request()).accepted;
    const ready = try runOnlyTask(&normal.ctx, allocator, io);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };
    defer failed_ctx.runtimeClearPendingEffectCopies();
    try app.update(ready, &failed_ctx);
    try std.testing.expectEqual(job.StartFailure.publication_task_start_failed, app.ai_review_jobs.find(key).?.phase.terminal.start_failed);
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review App task failure callbacks terminalize exact jobs and start the next FIFO item" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const first = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    const second = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    const failure_message = try failOnlyTask(&tc.ctx, allocator, .{ .start_failed = "injected" });
    try app.update(failure_message, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(first).?.phase.terminal == .start_failed);
    try std.testing.expectEqual(job.StartFailure.review_task_start_failed, app.ai_review_jobs.find(first).?.phase.terminal.start_failed);
    try std.testing.expect(app.ai_review_jobs.find(second).?.phase == .reviewing);

    var abandoned = try failOnlyTask(&tc.ctx, allocator, .runtime_abandoned);
    abandoned.deinitUndelivered(allocator);
    try std.testing.expect(app.ai_review_jobs.find(second).?.phase == .reviewing);
}

test "AI review App adopts a provider failure before starting the next FIFO item" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const first = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.requestWithExecutable("/definitely/missing/gitframe-codex")).accepted;
    const second = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    try std.testing.expectEqual(
        pipeline.FailureCode.provider_unavailable,
        app.ai_review_jobs.find(first).?.phase.terminal.pipeline.outcome.failed,
    );
    try std.testing.expect(app.ai_review_jobs.find(second).?.phase == .reviewing);
    var abandoned = try failOnlyTask(&tc.ctx, allocator, .runtime_abandoned);
    abandoned.deinitUndelivered(allocator);
}

test "AI review App publication runtime-start failure performs no Store mutation" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
    try std.testing.expect(try fixture.storeEmpty());
    const failure_message = try failOnlyTask(&tc.ctx, allocator, .{ .start_failed = "injected" });
    try app.update(failure_message, &tc.ctx);
    try std.testing.expectEqual(job.StartFailure.publication_task_start_failed, app.ai_review_jobs.find(key).?.phase.terminal.start_failed);
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review App quit confirmation cancels review before ReadyToPublish adoption" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    const queued = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    const entry = tc.ctx.takePendingTasksWith()[0];
    try app.update(.quit, &tc.ctx);
    try std.testing.expect(app.overlay.isQuitAiReviews());
    try std.testing.expect(!tc.ctx.shouldQuit());
    try app.update(.cancel_ai_review_quit, &tc.ctx);
    try std.testing.expect(!app.overlay.isQuitAiReviews());
    try app.update(.quit, &tc.ctx);
    try app.update(.confirm_ai_review_quit, &tc.ctx);
    try std.testing.expect(app.quit_after_ai_review_jobs);
    try std.testing.expect(app.ai_review_jobs.find(queued).?.phase.terminal.pipeline.outcome == .canceled);

    const message = entry.run(entry.ctx, allocator, io);
    try app.update(message, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase.terminal.pipeline.outcome == .canceled);
    try std.testing.expect(tc.ctx.shouldQuit());
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review App latches quit during publication and waits for finite reconciliation" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    const publication_entry = tc.ctx.takePendingTasksWith()[0];
    try app.update(.quit, &tc.ctx);
    try app.update(.confirm_ai_review_quit, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
    try std.testing.expect(!tc.ctx.shouldQuit());

    const terminal = publication_entry.run(publication_entry.ctx, allocator, io);
    try app.update(terminal, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase.terminal.pipeline.outcome == .published);
    try std.testing.expect(tc.ctx.shouldQuit());
}

test "AI review confirmed quit survives a later Git action until its terminal" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    const review_entry = tc.ctx.takePendingTasksWith()[0];
    try app.update(.quit, &tc.ctx);
    try app.update(.confirm_ai_review_quit, &tc.ctx);
    const action = beginAcceptedInertAction(&app);

    try app.update(review_entry.run(review_entry.ctx, allocator, io), &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase.terminal.pipeline.outcome == .canceled);
    try std.testing.expect(app.quit_after_ai_review_jobs);
    try std.testing.expect(!tc.ctx.shouldQuit());

    try app.update(.{ .action_finished = .{ .assist_commit_message = .{
        .pending = action,
        .repo_root = try allocator.dupe(u8, fixture.repo_path),
        .action_id = try allocator.dupe(u8, "quit-regression"),
        .launch_revision = 0,
        .mode = .generate,
        .result = .{ .failed_static = "injected terminal" },
    } } }, &tc.ctx);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(!app.quit_after_ai_review_jobs);
    try std.testing.expect(tc.ctx.shouldQuit());
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review undelivered ReadyToPublish releases payload without changing App state" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
    var message = try runOnlyTask(&tc.ctx, allocator, io);
    try std.testing.expect(message.ai_review_job.review_finished.outcome.pipeline == .ready);
    message.deinitUndelivered(allocator);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
    try std.testing.expect(try fixture.storeEmpty());
}
