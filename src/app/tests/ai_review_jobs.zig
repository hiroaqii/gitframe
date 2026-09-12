const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_actions = @import("../actions.zig");
const app_message = @import("../message.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");
const compare_submission = @import("../pages/compare/ai_review_submission.zig");
const committed = @import("../../committed_review.zig");
const git_command = @import("../../git/command.zig");
const git_review = @import("../../git/committed_review.zig");
const job = @import("../../ai_review/job.zig");
const codex = @import("../../ai_review/adapters/codex/adapter.zig");
const pipeline = @import("../../ai_review/runner.zig");
const root_capability = @import("../../repo/root_capability.zig");
const repo_discovery = @import("../../repo/discovery.zig");
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
            .{},
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

fn prepareCompareSubmissionApp(app: *App, fixture: *PipelineFixture) !void {
    const allocator = fixture.allocator;
    errdefer deinitCompareSubmissionApp(app, allocator);
    app.user_config.ai_review.codex_executable = fixture.executable;
    app.configured_review_store = try fixture.store.clone(allocator);
    app.repo_session.repo_state.discovery = repo_discovery.DiscoveryResult{ .single_repo = .{
        .label = try allocator.dupe(u8, "repo"),
        .display_path = try allocator.dupe(u8, fixture.repo_path),
        .canonical_root = try allocator.dupe(u8, fixture.repo_path),
    } };
    app.repo_session.repo_state.root = try fixture.root.duplicate();
    app.pages.compare.basis = .{
        .base = .{
            .full_ref = try allocator.dupe(u8, "refs/heads/review-base"),
            .display_name = try allocator.dupe(u8, "review-base"),
            .kind = .local,
        },
        .head_display = try allocator.dupe(u8, "main"),
        .target = fixture.target,
        .ahead_count = 1,
    };
    app.pages.compare.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/review-base"),
        .display_name = try allocator.dupe(u8, "review-base"),
        .kind = .local,
    };
    app.pages.compare.diff.load.state = .{ .empty = .no_changes };
    app.pages.compare.diff.accepted_repository_identity = .{
        .repo_epoch = app.repo_session.repo_epoch,
        .root_identity = fixture.root.identity,
    };
    app.pages.compare.beginAiReviewModal();
    app.pages.compare.ai_review_modal.paste("bounded context");
}

fn deinitCompareSubmissionApp(app: *App, allocator: std.mem.Allocator) void {
    app.pages.compare.deinit(allocator);
    if (app.configured_review_store) |*store| store.deinit(allocator);
    app.configured_review_store = null;
    app.repo_session.deinit(allocator);
    app.ai_review_jobs.deinit();
}

fn compareSubmissionController(app: *App) compare_submission.Controller {
    return .{
        .page = &app.pages.compare,
        .repo = app.repo_session.view(),
        .store = if (app.configured_review_store) |*store| store else null,
        .codex_executable = app.user_config.ai_review.codex_executable,
        .codex_model = app.user_config.ai_review.codex_model,
        .env_map = app.env_map,
        .jobs = &app.ai_review_jobs,
    };
}

test "Compare AI review submission owns exact authority and bounded rejection cleanup" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try PipelineFixture.init(allocator, std.testing.io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator };
    try prepareCompareSubmissionApp(&app, &fixture);
    defer deinitCompareSubmissionApp(&app, allocator);

    const accepted = compareSubmissionController(&app).submit(allocator).accepted;
    const record = app.ai_review_jobs.find(accepted).?;
    try std.testing.expect(record.scope.repository.eql(fixture.root.identity));
    try std.testing.expect(record.scope.target.eql(&fixture.target));
    try std.testing.expect(record.request.?.matchesScope(fixture.root.identity, &fixture.target));
    try std.testing.expectEqualStrings("bounded context", record.request.?.review_context);
    try std.testing.expect(!app.pages.compare.ai_review_modal.open);

    app.pages.compare.beginAiReviewModal();
    app.user_config.ai_review.codex_executable = null;
    try std.testing.expectEqual(compare_submission.Failure.codex_not_configured, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expect(app.pages.compare.ai_review_modal.open);
    try std.testing.expectEqualStrings("Set [ai_review].codex_executable before starting", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.user_config.ai_review.codex_executable = "codex";
    try std.testing.expectEqual(compare_submission.Failure.invalid_executable, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqualStrings("Codex executable must be an absolute file path", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.user_config.ai_review.codex_executable = fixture.executable;
    app.user_config.ai_review.codex_model = "x" ** 129;
    try std.testing.expectEqual(compare_submission.Failure.invalid_model, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqualStrings("Configured Codex model is invalid", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.user_config.ai_review.codex_model = null;

    const configured_store = app.configured_review_store;
    app.configured_review_store = null;
    try std.testing.expectEqual(compare_submission.Failure.store_not_configured, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqualStrings("Set [ai_review].store_root before starting", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.configured_review_store = configured_store;

    const accepted_base = app.pages.compare.base_target;
    app.pages.compare.base_target = null;
    try std.testing.expectEqual(compare_submission.Failure.target_missing, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqualStrings("Comparison target is unavailable; reload Compare", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.pages.compare.base_target = accepted_base;

    app.pages.compare.diff.accepted_repository_identity.?.repo_epoch += 1;
    try std.testing.expectEqual(compare_submission.Failure.comparison_changed, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.pages.compare.diff.accepted_repository_identity.?.repo_epoch -= 1;

    {
        const capability = &app.repo_session.repo_state.root.?;
        const valid_handle = capability.handle;
        capability.handle = -1;
        defer capability.handle = valid_handle;
        try std.testing.expectEqual(compare_submission.Failure.request_failed, compareSubmissionController(&app).submit(allocator).rejected);
        try std.testing.expectEqualStrings("Could not prepare AI review; check repository access and runtime resources", app.pages.compare.ai_review_modal.failure.text());
        try std.testing.expect(std.mem.indexOf(u8, app.pages.compare.ai_review_modal.failure.text(), "memory") == null);
        try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    }

    const selected_base = app.pages.compare.base_target.?;
    app.pages.compare.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/stale-base"),
        .display_name = try allocator.dupe(u8, "stale-base"),
        .kind = .local,
    };
    try std.testing.expectEqual(compare_submission.Failure.target_changed, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expectEqual(@as(usize, 1), app.ai_review_jobs.retained_count);
    app.pages.compare.base_target.?.deinit(allocator);
    app.pages.compare.base_target = selected_base;

    while (app.ai_review_jobs.retained_count < @import("../../ai_review/job_owner.zig").capacity) {
        const outcome = compareSubmissionController(&app).submit(allocator);
        try std.testing.expect(outcome == .accepted);
        app.pages.compare.beginAiReviewModal();
        app.pages.compare.ai_review_modal.paste("bounded context");
    }
    try std.testing.expectEqual(compare_submission.Failure.capacity, compareSubmissionController(&app).submit(allocator).rejected);
    try std.testing.expect(app.pages.compare.ai_review_modal.open);
    try std.testing.expectEqualStrings("AI review queue is full; dismiss a finished job", app.pages.compare.ai_review_modal.failure.text());
    try std.testing.expectEqual(@import("../../ai_review/job_owner.zig").capacity, app.ai_review_jobs.retained_count);
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
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        var failed_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };
        defer failed_ctx.runtimeClearPendingEffectCopies();
        const key = app.enqueueAiReview(&failed_ctx, fixture.scope(), try fixture.request()).accepted;
        const record = app.ai_review_jobs.find(key).?;
        try std.testing.expectEqual(job.StartFailure.review_task_start_failed, record.phase.terminal.start_failed);
        var buffer: [2048]u8 = undefined;
        const detail = @import("../ai_review_diagnostics.zig").format(&buffer, record);
        try std.testing.expect(std.mem.indexOf(u8, detail, "Stage: Review task start") != null);
        try std.testing.expect(std.mem.indexOf(u8, detail, "OutOfMemory") == null);
        try std.testing.expectEqualStrings("", app.status.text());
        var normal_ctx: chasen.testing.TestCtx(App.Msg) = .{};
        defer normal_ctx.resetTransient();
        const open_details = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f2 } }) orelse return error.ExpectedAiReviewDetails;
        try app.update(open_details, &normal_ctx.ctx);
        try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
    }

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
    try std.testing.expectEqualStrings("", app.status.text());
    const open_details = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f2 } }) orelse return error.ExpectedAiReviewDetails;
    try app.update(open_details, &normal.ctx);
    try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
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
    var detail_buffer: [2048]u8 = undefined;
    const detail = @import("../ai_review_diagnostics.zig").format(&detail_buffer, app.ai_review_jobs.find(first).?);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Stage: Review task start") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "injected") == null);
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
        .executable_missing,
        app.ai_review_jobs.find(first).?.phase.terminal.pipeline.outcome.failed.provider_unavailable,
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
    var detail_buffer: [2048]u8 = undefined;
    const detail = @import("../ai_review_diagnostics.zig").format(&detail_buffer, app.ai_review_jobs.find(key).?);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Stage: Save task start") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "injected") == null);
    try std.testing.expect(try fixture.storeEmpty());
    try std.testing.expectEqualStrings("", app.status.text());
    const open_details = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f2 } }) orelse return error.ExpectedAiReviewDetails;
    try app.update(open_details, &tc.ctx);
    try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
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

test "AI review runtime-abandoned callbacks only release review and publication payloads" {
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
        var abandoned = try failOnlyTask(&tc.ctx, allocator, .runtime_abandoned);
        abandoned.deinitUndelivered(allocator);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
        try std.testing.expect(!app.ai_review_jobs.find(key).?.unread);
    }

    {
        var app: App = .{ .allocator = allocator };
        defer app.ai_review_jobs.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = .{};
        defer tc.resetTransient();
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.request()).accepted;
        try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
        var abandoned = try failOnlyTask(&tc.ctx, allocator, .runtime_abandoned);
        abandoned.deinitUndelivered(allocator);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .publishing);
        try std.testing.expect(!app.ai_review_jobs.find(key).?.unread);
        try std.testing.expect(try fixture.storeEmpty());
    }
}

test "AI review input diagnostic survives task delivery page changes and exact detail selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator, .active_page = .compare, .terminal_size = .{ .width = 56, .height = 16 } };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();
    const request = try pipeline.Request.init(allocator, fixture.root, null, &fixture.store, fixture.repo_path, fixture.target, .{ .base_label = "base-枝" ** 30, .head_label = "head-枝" ** 30 }, .{ .codex = try codex.Request.init(allocator, "/must-not-launch-codex", null) }, "x" ** (codex.max_context_bytes + 1), .{});
    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), request).accepted;
    app.repo_session.repo_epoch = 99;
    app.active_page = .config;
    const message = try runOnlyTask(&tc.ctx, allocator, io);
    const evidence = message.ai_review_job.review_finished.outcome.pipeline.terminal.outcome.failed.input_too_large;
    var stale = message;
    stale.ai_review_job.review_finished.key.generation += 1;
    try app.update(stale, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
    var discarded = message;
    discarded.deinitUndelivered(allocator);
    try app.update(message, &tc.ctx);
    const record = app.ai_review_jobs.find(key).?;
    try std.testing.expectEqualDeep(evidence, record.phase.terminal.pipeline.outcome.failed.input_too_large);
    try std.testing.expectEqualStrings("repo", record.display.repository.slice());
    try std.testing.expect(std.mem.endsWith(u8, record.display.base.slice(), "…"));
    try std.testing.expect(record.scope.eql(&fixture.scope()));
    try app.update(app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f2 } }).?, &tc.ctx);
    try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
    try std.testing.expect(record.unread);
    try app.update(.{ .ai_review_details = .end }, &tc.ctx);
    try std.testing.expect(app.overlay.kind.ai_review_details.scroll > 0);
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &tc.ctx);
    const viewport = @import("../view.zig").aiReviewDetailViewport(@import("../shell_layout.zig").contentSize(app.terminal_size), record);
    try std.testing.expect(app.overlay.kind.ai_review_details.scroll <= viewport.max_scroll);
    const second = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.requestWithExecutable("/missing-codex")).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.find(second).?.phase == .terminal);
    try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
    try app.update(.{ .ai_review_details = .close }, &tc.ctx);
    try std.testing.expect(record.unread);
    try app.update(.{ .ai_review_details = .open }, &tc.ctx);
    try std.testing.expect(app.ai_review_jobs.dismiss(key, fixture.root.identity));
    const third = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.requestWithExecutable("/missing-codex")).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    try std.testing.expect(app.overlay.kind == .none);
    try std.testing.expect(app.ai_review_jobs.find(key) == null);
    try std.testing.expect(!third.eql(key));
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review pipeline plan limit reaches retained job without provider launch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    const limits = @import("../../ai_review/limits.zig");
    try fixture.repo.writeFile(io, .{ .sub_path = "sample.txt", .data = "x" ** (limits.max_diff_line_bytes + 1) ++ "\n" });
    try runCommand(allocator, io, fixture.repo, &.{ "git", "add", "sample.txt" });
    try runCommand(allocator, io, fixture.repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "oversized line" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const resolved = try git_review.resolveTarget(allocator, io, .{ .cwd = fixture.root.dir(), .environment = &environment }, .{
        .source_kind = .branch_range,
        .base = "refs/heads/review-base",
        .head = "refs/heads/main",
    });
    fixture.target = resolved.target;
    var app: App = .{ .allocator = allocator };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();
    const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.requestWithExecutable("/must-not-launch-codex")).accepted;
    try app.update(try runOnlyTask(&tc.ctx, allocator, io), &tc.ctx);
    const record = app.ai_review_jobs.find(key).?;
    const limit = record.phase.terminal.pipeline.outcome.failed.input_too_large.?;
    try std.testing.expectEqual(.diff_line_bytes, limit.resource);
    try std.testing.expectEqual(limits.max_diff_line_bytes, limit.allowed);
    try std.testing.expect(limit.observed > limit.allowed);
    try std.testing.expectEqual(.at_least, limit.observation);
    var buffer: [2048]u8 = undefined;
    const detail = @import("../ai_review_diagnostics.zig").format(&buffer, record);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Resource: diff_line_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "Before Codex starts") != null);
    try std.testing.expect(try fixture.storeEmpty());
}

test "AI review pipeline classifies pre-provider validation and Store failures" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    {
        var fixture = try PipelineFixture.init(allocator, io);
        defer fixture.deinit();
        const request = try fixture.requestWithExecutable("/must-not-launch-codex");
        try fixture.repo.deleteTree(io, ".git");
        try fixture.repo.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: missing\n" });
        var result = pipeline.review(allocator, io, request, .{});
        defer result.deinit();
        try std.testing.expectEqual(pipeline.FailureCode.repository_unavailable, result.terminal.outcome.failed);
    }

    {
        var fixture = try PipelineFixture.init(allocator, io);
        defer fixture.deinit();
        fixture.target.head_oid = try committed.ObjectId.parse(.sha1, "f" ** 40);
        var result = pipeline.review(allocator, io, try fixture.requestWithExecutable("/must-not-launch-codex"), .{});
        defer result.deinit();
        try std.testing.expectEqual(pipeline.FailureCode.target_unavailable, result.terminal.outcome.failed);
    }

    {
        var fixture = try PipelineFixture.init(allocator, io);
        defer fixture.deinit();
        try runCommand(allocator, io, fixture.repo, &.{ "git", "config", "diff.algorithm", "definitely-invalid" });
        var result = pipeline.review(allocator, io, try fixture.requestWithExecutable("/must-not-launch-codex"), .{});
        defer result.deinit();
        try std.testing.expectEqual(pipeline.FailureCode.projection_failed, result.terminal.outcome.failed);
    }

    {
        var fixture = try PipelineFixture.init(allocator, io);
        defer fixture.deinit();
        const invalid_script =
            \\#!/bin/sh
            \\if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
            \\  printf '%s\n' 'codex-cli 999.0'
            \\  exit 0
            \\fi
            \\/bin/cat >/dev/null
            \\printf '%s\n' \
            \\  '{"type":"thread.started","thread_id":"fake"}' \
            \\  '{"type":"turn.started"}' \
            \\  '{"type":"item.completed","item":{"type":"agent_message","text":"{\"schema_version\":1,\"units\":[{\"ordinal\":1,\"candidate\":{\"findings\":[{\"start_location\":\"a9999\",\"end_location\":\"a9999\",\"severity\":\"warning\",\"title\":\"SECRET-CODE-SENTINEL\",\"body\":\"invalid anchor\"}]}}]}"}}' \
            \\  '{"type":"turn.completed"}'
        ;
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "codex-invalid-anchor", .data = invalid_script });
        const executable = try fixture.tmp.dir.realPathFileAlloc(io, "codex-invalid-anchor", allocator);
        defer allocator.free(executable);
        try runCommand(allocator, io, fixture.tmp.dir, &.{ "/bin/chmod", "0700", executable });
        var result = pipeline.review(allocator, io, try fixture.requestWithExecutable(executable), .{});
        defer result.deinit();
        try std.testing.expectEqual(pipeline.FailureCode.invalid_candidates, result.terminal.outcome.failed);
    }

    {
        var fixture = try PipelineFixture.init(allocator, io);
        defer fixture.deinit();
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "store-file", .data = "not a directory\n" });
        const store_file = try fixture.tmp.dir.realPathFileAlloc(io, "store-file", allocator);
        defer allocator.free(store_file);
        var unusable_store = try store_service.ConfiguredStore.initConfigured(allocator, store_file);
        defer unusable_store.deinit(allocator);
        const request = try pipeline.Request.init(
            allocator,
            fixture.root,
            null,
            &unusable_store,
            fixture.repo_path,
            fixture.target,
            null,
            .{ .codex = try codex.Request.init(allocator, fixture.executable, null) },
            "bounded context",
            .{},
        );
        var reviewed = pipeline.review(allocator, io, request, .{});
        defer reviewed.deinit();
        const ready = switch (reviewed) {
            .ready => |value| value,
            .terminal => return error.ExpectedReadyToPublish,
        };
        reviewed = .{ .terminal = .{ .outcome = .canceled } };
        const terminal = pipeline.publishReady(allocator, io, ready);
        try std.testing.expectEqual(pipeline.FailureCode.store_prepare_failed, terminal.outcome.failed);
    }
}

test "AI review diagnostics retain exact job identity through messages and F2" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try PipelineFixture.init(allocator, io);
    defer fixture.deinit();
    var app: App = .{ .allocator = allocator, .active_page = .compare, .terminal_size = .{ .width = 56, .height = 16 } };
    defer app.ai_review_jobs.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();
    const deadline = std.Io.Clock.Timestamp.now(io, .awake);
    var expired = pipeline.review(allocator, io, try fixture.requestWithExecutable("/must-not-start-provider"), .{ .deadline = deadline });
    defer expired.deinit();
    const before = expired.terminal.outcome.failed.timed_out.?;
    try std.testing.expectEqual(.before_provider, before.stage);
    try std.testing.expectEqual(.caller, before.owner);
    try std.testing.expectEqualDeep(std.Io.Duration.zero, before.budget);
    const uncertain_id = try committed.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const cases = [_]struct {
        outcome: pipeline.TerminalOutcome,
        expected: []const u8,
        additional: ?[]const u8 = null,
        forbidden: ?[]const u8 = null,
    }{
        .{ .outcome = .{ .failed = .repository_unavailable }, .expected = "Reload the repository" },
        .{ .outcome = .{ .failed = .target_unavailable }, .expected = "Restore or reload the fixed review target" },
        .{ .outcome = .{ .failed = .projection_failed }, .expected = "Stage: Before Codex starts" },
        .{ .outcome = .{ .failed = .input_failed }, .expected = "Check the review target and Context" },
        .{ .outcome = expired.terminal.outcome, .expected = "Remaining caller budget at pipeline entry" },
        .{ .outcome = .{ .failed = .{ .stream_too_large = .{ .resource = .stdout_bytes, .allowed = 2097152, .observed = 2097153, .observation = .at_least } } }, .expected = "Observed at least: 2097153 bytes" },
        .{ .outcome = .{ .failed = .{ .stream_too_large = .{ .resource = .stderr_bytes, .allowed = 65536, .observed = 65537, .observation = .at_least } } }, .expected = "Resource: stderr_bytes" },
        .{ .outcome = .{ .failed = .{ .final_answer_too_large = .{ .resource = .final_answer_bytes, .allowed = 65536, .observed = 65537, .observation = .exact } } }, .expected = "Observed: 65537 bytes" },
        .{ .outcome = .{ .failed = .{ .timed_out = .{ .stage = .provider_execution, .owner = .adapter, .budget = .fromSeconds(900) } } }, .expected = "Budget at entry: 15m" },
        .{ .outcome = .{ .failed = .{ .timed_out = .{ .stage = .version_probe, .owner = .caller, .budget = .fromMilliseconds(123) } } }, .expected = "Deadline owner: caller" },
        .{ .outcome = .{ .failed = .{ .timed_out = null } }, .expected = "duration / deadline owner: unknown" },
        .{ .outcome = .{ .failed = .{ .provider_unavailable = .executable_missing } }, .expected = "executable not found" },
        .{ .outcome = .{ .failed = .{ .provider_incompatible = .unexpected_event } }, .expected = "Stage: Answer decoding" },
        .{ .outcome = .{ .failed = .{ .provider_exit = .{ .classification = .authentication_response, .term = .{ .exited = 17 } } } }, .expected = "cause is not confirmed" },
        .{ .outcome = .{ .failed = .{ .provider_exit = .{ .classification = .cli_response, .term = .{ .exited = 2 } } } }, .expected = "Exit code: 2" },
        .{ .outcome = .{ .failed = .{ .provider_exit = .{ .classification = .other, .term = .{ .signal = @enumFromInt(9) } } } }, .expected = "Signal: 9" },
        .{ .outcome = .{ .failed = .{ .invalid_provider_result = .answer } }, .expected = "The answer was not accepted." },
        .{ .outcome = .{ .failed = .provider_failed }, .expected = "provider I/O" },
        .{ .outcome = .{ .failed = .invalid_candidates }, .expected = "Stage: Candidate validation" },
        .{ .outcome = .{ .failed = .store_prepare_failed }, .expected = "Stage: Store preparation" },
        .{ .outcome = .{ .failed = .artifact_failed }, .expected = "Stage: Artifact creation" },
        .{ .outcome = .{ .failed = .publish_failed }, .expected = "The final save state could not be confirmed.", .forbidden = "The review was not saved." },
        .{ .outcome = .{ .failed = .exact_reconciliation_failed }, .expected = "could not be verified against the expected metadata", .forbidden = "did not match" },
        .{ .outcome = .{ .failed = .{ .internal_error = .before_provider } }, .expected = "Check available memory and runtime resources" },
        .{ .outcome = .{ .failed = .{ .internal_error = null } }, .expected = "Stage: Unknown" },
        .{ .outcome = .{ .outcome_unknown = uncertain_id }, .expected = "Review ID: 123e4567-e89b-42d3-a456-426614174000", .additional = "Stage: Store publication or save verification" },
        .{ .outcome = .canceled, .expected = "Canceled by user" },
    };
    for (cases) |case| {
        const key = app.enqueueAiReview(&tc.ctx, fixture.scope(), try fixture.requestWithExecutable("/must-not-exist-provider")).accepted;
        var message = try runOnlyTask(&tc.ctx, allocator, io);
        message.ai_review_job.review_finished.outcome.pipeline.terminal.outcome = case.outcome;
        var stale = message;
        stale.ai_review_job.review_finished.key.generation += 1;
        try app.update(stale, &tc.ctx);
        try std.testing.expect(app.ai_review_jobs.find(key).?.phase == .reviewing);
        var undelivered = message;
        undelivered.deinitUndelivered(allocator);
        app.active_page = .config;
        app.repo_session.repo_epoch += 1;
        try app.update(message, &tc.ctx);
        const record = app.ai_review_jobs.find(key).?;
        try std.testing.expectEqualDeep(case.outcome, record.phase.terminal.pipeline.outcome);
        try std.testing.expect(record.scope.eql(&fixture.scope()));
        try app.update(app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f2 } }).?, &tc.ctx);
        try std.testing.expect(app.overlay.kind.ai_review_details.key.eql(key));
        var buffer: [2048]u8 = undefined;
        const detail = @import("../ai_review_diagnostics.zig").format(&buffer, record);
        try std.testing.expect(std.mem.indexOf(u8, detail, case.expected) != null);
        if (case.additional) |additional| try std.testing.expect(std.mem.indexOf(u8, detail, additional) != null);
        if (case.forbidden) |forbidden| try std.testing.expect(std.mem.indexOf(u8, detail, forbidden) == null);
        try std.testing.expect(std.mem.indexOf(u8, detail, fixture.target.head_oid.slice()) != null);
        try std.testing.expect(std.mem.indexOf(u8, detail, "SECRET-CODE-SENTINEL") == null);
        try app.update(.{ .ai_review_details = .close }, &tc.ctx);
        try std.testing.expect(record.unread);
        try app.update(.dismiss_ai_review_status, &tc.ctx);
        try std.testing.expect(app.ai_review_jobs.find(key) == null);
    }
    try std.testing.expect(try fixture.storeEmpty());
}
