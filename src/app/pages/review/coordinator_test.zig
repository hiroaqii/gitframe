//! Owner-local tests for Review coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const diff_basis = @import("../../diff_basis.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const app_test_support = @import("../../test_support.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const git_review = @import("../../../git/committed_review.zig");
const git_refs = @import("../../../git/refs.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const committed_review = @import("../../../committed_review.zig");
const review_store = @import("../../../review_store.zig");
const review_page = @import("../review.zig");
const review_coordinator = @import("coordinator.zig");

const ReviewLoadFinished = app_load.ReviewLoadFinished;
const ReviewLoadTask = app_load.ReviewLoadTask(app_message.Msg);
const ReviewBranchListLoadTask = app_load.ReviewBranchListLoadTask(app_message.Msg);
const ReviewHistoryScanTask = app_load.ReviewHistoryScanTask(app_message.Msg);
const ReviewHistorySelectionTask = app_load.ReviewHistorySelectionTask(app_message.Msg);

const TestApp = struct {
    allocator: ?std.mem.Allocator = null,
    active_page: page.Id = .review,
    repo_session: repo_session.State = .{},
    pages: struct { review: review_page.ReviewPageState = .{} } = .{},
    layout: diff_surface.Layout = .{ .width = 100, .height = 30 },
    store_path: review_store.ResolvedPath = .{ .unavailable = .no_state_home },

    const Msg = app_message.Msg;

    fn controller(self: *TestApp) review_coordinator.Controller {
        return .{
            .page_state = &self.pages.review,
            .repo = self.repo_session.view(),
            .layout = self.layout,
            .env_map = null,
            .store_path = &self.store_path,
        };
    }

    fn update(self: *TestApp, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .reload => try self.controller().refresh(ctx),
            .review => |review_msg| {
                var outcome = try self.controller().update(ctx, review_msg);
                defer outcome.deinit(ctx.allocator());
            },
            .load_finished => |finished| switch (finished) {
                .review => |review_finished| switch (review_finished) {
                    .source => |source| _ = try self.controller().finishLoad(ctx, source),
                    .branch_list => |branches| _ = self.controller().finishBranchList(ctx.allocator(), branches),
                    .history_scan => |history| _ = self.controller().finishHistoryScan(ctx.allocator(), history),
                    .history_selection => |selection| _ = try self.controller().finishHistorySelection(ctx, selection),
                    .history_normal_return => |normal| _ = try self.controller().finishHistoryNormalReturn(ctx, normal),
                },
                else => unreachable,
            },
            else => unreachable,
        }
        _ = try self.controller().applyDeferred(ctx);
    }
};

test "AI Reviews picker requests return to the event loop before captured workers complete" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
        .store_path = .{ .available = try allocator.dupe(u8, "/captured-ai-review-store") },
    };
    defer app.store_path.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    // Explicit open only publishes pending state and a captured task. The
    // worker has not run and no presentation has changed.
    try app.update(.{ .review = .open_ai_reviews }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .scan_loading);
    try std.testing.expect(app.pages.review.presentation == null);
    var queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const scan_completion = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .scan_loading);
    try app.update(scan_completion, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .scan_failed);

    // A retained row follows the same boundary: activation returns with one
    // captured worker and only completion delivery advances the terminal.
    const review_id = try committed_review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    const rows = try allocator.alloc(review_store.history.RunSummary, 1);
    rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    app.pages.review.ai_reviews.scan_result = .{ .history = .{
        .snapshot = undefined,
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.history.Diagnostic, 0),
        .skipped_count = 0,
        .orphan_count = 0,
    } };
    const labels = [_][]const u8{"reviewer"};
    try app.pages.review.ai_reviews.filter.apply(allocator, &labels, "");
    app.pages.review.ai_reviews.phase = .ready;
    app.pages.review.ai_reviews.focus = 1;
    try app.update(.{ .review = .ai_reviews_activate }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_loading);
    try std.testing.expect(app.pages.review.presentation == null);
    queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const selection_completion = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_loading);
    try app.update(selection_completion, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_failed);
    try std.testing.expect(app.pages.review.presentation == null);

    // Selection-time missing keeps Enter inert, while r starts a fresh scan
    // generation whose completion can publish restored availability.
    app.pages.review.ai_reviews.phase = .ready;
    app.pages.review.ai_reviews.focus = 1;
    try app.update(.{ .review = .ai_reviews_activate }, &ctx);
    queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const stale_selection = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    app.pages.review.ai_reviews.failSelection(review_id, .target_unavailable);
    try app.update(stale_selection, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_failed);
    try std.testing.expect(app.pages.review.ai_reviews.rows()[0].availability == .missing);
    try app.update(.{ .review = .ai_reviews_activate }, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);

    const missing_generation = app.pages.review.ai_reviews.generation;
    try app.update(.{ .review = .ai_reviews_refresh_or_retry }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .scan_loading);
    try std.testing.expect(app.pages.review.ai_reviews.generation != missing_generation);
    queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const scan_task: *ReviewHistoryScanTask = @ptrCast(@alignCast(queued[0].ctx));
    const scan_identity = scan_task.identity;
    const scan_generation = scan_task.generation;
    ReviewHistoryScanTask.destroy(scan_task, allocator);
    const refreshed_rows = try allocator.alloc(review_store.history.RunSummary, 1);
    refreshed_rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    try app.update(.{ .load_finished = .{ .review = .{ .history_scan = .{
        .identity = scan_identity,
        .generation = scan_generation,
        .store_root = try allocator.dupe(u8, "/captured-ai-review-store"),
        .result = .{ .scanned = .{ .history = .{
            .snapshot = undefined,
            .rows = refreshed_rows,
            .diagnostics = try allocator.alloc(review_store.history.Diagnostic, 0),
            .skipped_count = 0,
            .orphan_count = 0,
        } } },
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .ready);
    try std.testing.expect(app.pages.review.ai_reviews.rows()[0].availability == .available);

    // Exercise the production request route from a pinned presentation. The
    // failure completion must be the first state mutation after pending.
    app.pages.review.presentation = .{ .pinned_ai = undefined };
    defer app.pages.review.presentation = null;
    try app.update(.{ .review = .return_to_normal_review }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .return_loading);
    queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const normal_completion = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .return_loading);
    try app.update(normal_completion, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .return_failed);
    try std.testing.expect(app.pages.review.isPinnedAi());
}

test "AI Reviews picker pinned acceptance retires in-flight and deferred ordinary Review refreshes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    try roots.tmp.dir.createDir(std.testing.io, "review-store", .fromMode(0o700));
    const store_root = try roots.tmp.dir.realPathFileAlloc(std.testing.io, "review-store", allocator);
    defer allocator.free(store_root);

    inline for (.{ false, true }) |defer_ordinary_completion| {
        try expectPinnedAcceptanceRetiresOrdinaryRefresh(
            allocator,
            roots.a,
            store_root,
            defer_ordinary_completion,
        );
    }
}

test "Review document navigation and diff wheel share rendered cursor authority" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .focus = .sidebar,
                .diff_scroll = 2,
            },
        } },
        .layout = .{ .width = 140, .height = 9 },
    };
    defer app.pages.review.deinit(allocator);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    const old_scroll = app.pages.review.viewer.diff_scroll;
    const navigation = app.controller().navigation();
    var update_adapter = navigation.updateAdapter();
    const body = update_adapter.bodyController();
    const visible_rows = body.view().view.diffVisibleRows();
    const line_count = body.view().sourceDiffLineCount();

    app.pages.review.viewer.diff_cursor = body.view().selectedCoordinateAtOffset(0) orelse
        return error.ExpectedCoordinate;
    try app.update(.{ .review = .{ .shared = .document_last } }, &ctx);
    var document_adapter = app.controller().navigation().updateAdapter();
    try std.testing.expectEqual(
        @as(?usize, line_count - 1),
        document_adapter.bodyController().view().selectedDiffCursorOffset(),
    );
    try app.update(.{ .review = .{ .shared = .document_first } }, &ctx);
    document_adapter = app.controller().navigation().updateAdapter();
    try std.testing.expectEqual(@as(?usize, 0), document_adapter.bodyController().view().selectedDiffCursorOffset());
    try app.update(.{ .review = .{ .shared = .half_page_down } }, &ctx);
    document_adapter = app.controller().navigation().updateAdapter();
    try std.testing.expectEqual(
        @as(?usize, @min(@max(visible_rows / 2, 1), line_count - 1)),
        document_adapter.bodyController().view().selectedDiffCursorOffset(),
    );

    app.pages.review.viewer.display_mode = .side_by_side;
    try app.update(.{ .review = .{ .shared = .page_diff_down } }, &ctx);
    app.pages.review.viewer.display_mode = .unified;
    app.pages.review.viewer.diff_scroll = old_scroll;
    app.pages.review.viewer.diff_cursor = body.view().selectedCoordinateAtOffset(old_scroll) orelse
        return error.ExpectedCoordinate;

    try app.update(.{ .review = .{ .shared = .mouse_diff_wheel_down } }, &ctx);

    var result_adapter = app.controller().navigation().updateAdapter();
    const result_body = result_adapter.bodyController();
    try std.testing.expectEqual(diff_surface.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(old_scroll + 1, app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(
        app.pages.review.viewer.diff_scroll + visible_rows / 2,
        result_body.view().selectedDiffCursorOffset().?,
    );
}

test "Review coordinator returns shared drag auto-scroll outcome" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
                .focus = .diff,
                .diff_scroll = 2,
            },
            .selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .side = .old,
                .mode = .line,
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 1 },
                .anchor_cell = .{ .col = 20, .row = 4 },
            } },
        } },
        .layout = .{ .width = 100, .height = 9 },
    };
    defer app.pages.review.deinit(allocator);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    var outcome = try app.controller().update(&ctx, .{
        .shared = .{
            .mouse_diff_auto_scroll_step = .{
                .direction = .up,
                // The opposite side is visible at this row, but the live drag's
                // starting side remains authoritative.
                .endpoint = .{ .col = 80, .row = 3 },
            },
        },
    });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, outcome.auto_scroll.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.diff_scroll);
    const selection = app.pages.review.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(selection.side == .old);
    try std.testing.expectEqual(@as(usize, 1), selection.focus.line_index);
}

test "Review reload retries user intent and preserves accepted display on failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .review,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    if (app.pages.review.base_target) |*target| target.deinit(allocator);
    app.pages.review.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/topic"),
        .display_name = try allocator.dupe(u8, "topic"),
        .kind = .local,
    };

    try app.update(.reload, &ctx);
    const failed_task: *ReviewLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqualStrings("refs/heads/topic", failed_task.target.?.full_ref);
    const failed_identity = failed_task.identity;
    const failed_generation = failed_task.generation;
    try abandonSingleQueuedTask(&ctx, allocator);
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppBasisFailureFinished(
        allocator,
        failed_identity,
        failed_generation,
        "topic",
    ) } } }, &ctx);

    try std.testing.expectEqualStrings("main", app.pages.review.normalBasisConst().?.base.display_name);
    try std.testing.expect(app.pages.review.load.state == .loaded);
    try std.testing.expectEqualStrings("topic", app.pages.review.basis_failure.?.attempted.display_name);
    try std.testing.expectEqualStrings("topic", app.pages.review.base_target.?.display_name);

    try app.update(.reload, &ctx);
    const retry_task: *ReviewLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqualStrings("refs/heads/topic", retry_task.target.?.full_ref);
    try std.testing.expect(app.pages.review.basis_failure == null);
    try std.testing.expectEqualStrings("main", app.pages.review.normalBasisConst().?.base.display_name);
}

test "Review refresh restores its anchor after atomic replacement" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .review,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    const selected_before = app.pages.review.viewer.selected_target.?;

    try app.update(.reload, &ctx);
    try std.testing.expect(app.pages.review.refresh_anchor != null);
    const stale_task: *ReviewLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const stale_identity = stale_task.identity;
    const stale_generation = stale_task.generation;
    try app.update(.reload, &ctx);
    const current_task: *ReviewLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const identity = current_task.identity;
    const generation = current_task.generation;
    try std.testing.expectEqual(@as(usize, 2), abandonQueuedTasks(&ctx, allocator));
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        stale_identity,
        stale_generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expect(app.pages.review.refresh_anchor != null);
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        identity,
        generation,
        'a',
        'b',
    ) } } }, &ctx);

    try std.testing.expect(app.pages.review.refresh_anchor == null);
    try std.testing.expectEqual(selected_before, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(
        diff_view_model.BodyCoordinate{ .hunk_header = 0 },
        app.pages.review.viewer.diff_cursor,
    );
}

test "Review app route retains viewed marks only for an unchanged oid pair" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { base: u8, head: u8, retained: bool }{
        .{ .base = 'a', .head = 'b', .retained = true },
        .{ .base = 'd', .head = 'b', .retained = false },
        .{ .base = 'a', .head = 'e', .retained = false },
    };
    for (cases) |case| {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .review,
            .repo_session = .{
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, "/repo") },
            },
        };
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        _ = app.pages.review.activate(app.repo_session.repo_epoch);
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

        const initial = app.pages.review.beginRefresh().?;
        try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
            allocator,
            initial.identity,
            initial.generation,
            'a',
            'b',
        ) } } }, &ctx);
        const first_loaded = switch (app.pages.review.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedReview,
        };
        try app.pages.review.reviewed_store.set(allocator, "/repo", first_loaded.document.files[0], true);
        first_loaded.reviewed_files[0] = true;

        const replacement = app.pages.review.beginRefresh().?;
        try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
            allocator,
            replacement.identity,
            replacement.generation,
            case.base,
            case.head,
        ) } } }, &ctx);
        const second_loaded = switch (app.pages.review.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedReview,
        };
        try std.testing.expectEqual(case.retained, second_loaded.reviewed_files[0]);
    }
}

test "Review picker rejects replaced and closed generations through the App route" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .review,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .review = .open_base_picker }, &ctx);
    const first: *ReviewBranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const first_identity = first.identity;
    const first_generation = first.generation;
    try app.update(.{ .review = .open_base_picker }, &ctx);
    const second: *ReviewBranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const second_identity = second.identity;
    const second_generation = second.generation;
    try std.testing.expect(second_generation > first_generation);

    try app.update(.{ .load_finished = .{ .review = .{ .branch_list = .{
        .identity = first_identity,
        .generation = first_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "stale", .oid = "1111111111111111111111111111111111111111" }}),
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.base_picker.accepted == null);
    try app.update(.{ .load_finished = .{ .review = .{ .branch_list = .{
        .identity = second_identity,
        .generation = second_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "accepted", .oid = "2222222222222222222222222222222222222222" }}),
    } } } }, &ctx);
    try std.testing.expectEqualStrings("accepted", app.pages.review.base_picker.accepted.?.branches[0].name);

    try app.update(.{ .review = .close_base_picker }, &ctx);
    try std.testing.expect(app.pages.review.base_picker.accepted == null);
    try app.update(.{ .load_finished = .{ .review = .{ .branch_list = .{
        .identity = second_identity,
        .generation = second_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "closed", .oid = "3333333333333333333333333333333333333333" }}),
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.base_picker.accepted == null);
}

test "Review load route admits failure intent through the Review owner" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .repo_session = .{ .repo_epoch = 12 },
    };
    defer app.pages.review.deinit(allocator);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    const request = app.pages.review.beginRefresh().?;
    var tc: chasen.testing.TestCtx(TestApp.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .load_finished = .{ .review = .{ .source = .{
        .identity = request.identity,
        .generation = request.generation,
        .result = .{ .basis_failed = .{
            .kind = .missing_base_ref,
            .attempted = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/gone"),
                .display_name = try allocator.dupe(u8, "gone"),
                .kind = .local,
            },
        } },
    } } } }, &tc.ctx);

    try std.testing.expectEqualStrings("gone", app.pages.review.basis_failure.?.attempted.display_name);
}

const review_app_test_diff =
    "diff --git a/src/compare.zig b/src/compare.zig\n" ++
    "--- a/src/compare.zig\n" ++
    "+++ b/src/compare.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

fn reviewAppTestOid(byte: u8) diff_basis.Oid {
    var oid: diff_basis.Oid = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn reviewHistoryRow(
    allocator: std.mem.Allocator,
    review_id: committed_review.ReviewId,
    availability: git_review.TargetAvailability,
) !review_store.history.RunSummary {
    return .{
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = reviewAppTestOid('a'),
            .head_oid = reviewAppTestOid('b'),
            .diff_base_oid = reviewAppTestOid('a'),
        },
        .status = .approved,
        .created_at = "2026-08-20T00:00:00Z".*,
        .created_at_unix = 1,
        .producer_name = try allocator.dupe(u8, "reviewer"),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = 1,
        .availability = availability,
        .artifact_snapshot = .{
            .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
            .draft_state = .absent,
            .draft_digest = null,
            .result_digest = null,
        },
    };
}

fn expectPinnedAcceptanceRetiresOrdinaryRefresh(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    store_root: []const u8,
    defer_ordinary_completion: bool,
) !void {
    var app: TestApp = .{
        .allocator = allocator,
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) } },
        .store_path = .{ .available = try allocator.dupe(u8, store_root) },
    };
    defer app.store_path.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    const normal_revision = app.pages.review.source_session_revision;

    try app.update(.reload, &ctx);
    const refresh_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), refresh_tasks.len);
    const ordinary_task: *ReviewLoadTask = @ptrCast(@alignCast(refresh_tasks[0].ctx));
    const ordinary_identity = ordinary_task.identity;
    const ordinary_generation = ordinary_task.generation;
    ReviewLoadTask.destroy(ordinary_task, allocator);

    if (defer_ordinary_completion) {
        app.pages.review.selection_owner = .{ .diff = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/compare.zig" } },
            .side = .new,
            .mode = .line,
            .anchor = .{ .hunk_index = 0, .line_index = 0 },
            .focus = .{ .hunk_index = 0, .line_index = 1 },
        } };
        try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
            allocator,
            ordinary_identity,
            ordinary_generation,
            'c',
            'd',
        ) } } }, &ctx);
        try std.testing.expect(app.pages.review.deferred_load_apply != null);
        try std.testing.expect(app.pages.review.refresh_anchor != null);
    }

    var store = try review_store.StoreRootCapability.openCanonical(store_root);
    defer store.deinit();
    const repository_id = try committed_review.ReviewRepositoryId.parse("723e4567-e89b-42d3-a456-426614174000");
    const store_snapshot: review_store.history.StoreSnapshot = .{
        .root_device = store.directory.metadata.device,
        .root_inode = store.directory.metadata.inode,
        .repository_locator = .{
            .device = app.repo_session.repo_state.root.?.identity.device,
            .inode = app.repo_session.repo_state.root.?.identity.inode,
        },
        .review_repository_id = repository_id,
    };
    const review_id = try committed_review.ReviewId.parse(if (defer_ordinary_completion)
        "823e4567-e89b-42d3-a456-426614174000"
    else
        "923e4567-e89b-42d3-a456-426614174000");
    const pinned_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = reviewAppTestOid('e'),
        .head_oid = reviewAppTestOid('f'),
        .diff_base_oid = reviewAppTestOid('e'),
    };
    var pinned_bundle = try reviewHistoryPinnedBundle(
        allocator,
        store_snapshot,
        repository_id,
        review_id,
        pinned_target,
    );
    var bundle_owned = true;
    defer if (bundle_owned) pinned_bundle.deinit(allocator);

    const rows = try allocator.alloc(review_store.history.RunSummary, 1);
    rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    rows[0].target = pinned_target;
    rows[0].status = .new;
    rows[0].finding_count = 0;
    rows[0].artifact_snapshot = review_store.ArtifactSnapshot.fromLoaded(&pinned_bundle.selection.artifacts);
    app.pages.review.ai_reviews.scan_result = .{ .history = .{
        .snapshot = store_snapshot,
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.history.Diagnostic, 0),
        .skipped_count = 0,
        .orphan_count = 0,
    } };
    const labels = [_][]const u8{"reviewer"};
    try app.pages.review.ai_reviews.filter.apply(allocator, &labels, "");
    app.pages.review.ai_reviews.identity = app.pages.review.activation.currentIdentity();
    app.pages.review.ai_reviews.root_identity = app.repo_session.repo_state.root.?.identity;
    app.pages.review.ai_reviews.phase = .ready;
    app.pages.review.ai_reviews.focus = 1;
    try app.update(.{ .review = .ai_reviews_activate }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_loading);
    const selection_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), selection_tasks.len);
    const selection_task: *ReviewHistorySelectionTask = @ptrCast(@alignCast(selection_tasks[0].ctx));
    const selection_identity = selection_task.identity;
    const selection_generation = selection_task.generation;
    ReviewHistorySelectionTask.destroy(selection_task, allocator);

    const completion_store_root = try allocator.dupe(u8, store_root);
    bundle_owned = false;
    try app.update(.{ .load_finished = .{ .review = .{ .history_selection = .{
        .identity = selection_identity,
        .generation = selection_generation,
        .store_root = completion_store_root,
        .review_id = review_id,
        .result = .{ .loaded = pinned_bundle },
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.isPinnedAi());
    const pinned_revision = app.pages.review.source_session_revision;
    try std.testing.expectEqual(normal_revision +% 1, pinned_revision);
    try std.testing.expect(app.pages.review.activeAiReviewId().?.eql(review_id));
    try std.testing.expect(app.pages.review.pinnedAiConst().?.target().eql(&pinned_target));

    if (!defer_ordinary_completion) {
        try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
            allocator,
            ordinary_identity,
            ordinary_generation,
            'c',
            'd',
        ) } } }, &ctx);
    }
    try std.testing.expect(app.pages.review.deferred_load_apply == null);
    try std.testing.expect(app.pages.review.refresh_anchor == null);
    try std.testing.expectEqual(pinned_revision, app.pages.review.source_session_revision);
    try std.testing.expect(app.pages.review.activeAiReviewId().?.eql(review_id));
    try std.testing.expect(app.pages.review.pinnedAiConst().?.target().eql(&pinned_target));
}

fn reviewHistoryPinnedBundle(
    allocator: std.mem.Allocator,
    snapshot: review_store.history.StoreSnapshot,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
) !app_load.PinnedReviewLoadedBundle {
    const producer: committed_review.Producer = .{ .name = "reviewer", .model = "gpt-test" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-20T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    errdefer allocator.free(findings_bytes);
    var findings = try committed_review.FindingSet.parseStrict(allocator, findings_bytes);
    errdefer findings.deinit();
    const manifest_value: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = "2026-08-20T00:00:00Z",
        .display = .{ .base_label = "main", .head_label = "topic" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest_value.writeCanonical(allocator);
    errdefer allocator.free(manifest_bytes);
    var manifest = try committed_review.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    errdefer manifest.deinit();
    const patch_bytes = try allocator.dupe(u8, "");
    errdefer allocator.free(patch_bytes);

    return .{
        .selection = .{
            .snapshot = snapshot,
            .artifacts = .{
                .manifest_bytes = manifest_bytes,
                .findings_bytes = findings_bytes,
                .draft_bytes = null,
                .result_bytes = null,
                .manifest = manifest,
                .findings = findings,
                .draft = null,
                .result = null,
                .state = .new,
                .created_at_unix = 0,
                .retained_draft_diagnostic = null,
            },
            .projection = .{ .target = target, .patch_bytes = patch_bytes },
        },
        .diff = .empty,
    };
}

fn reviewAppLoadedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base_byte: u8,
    head_byte: u8,
) !ReviewLoadFinished {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    const head_display = try allocator.dupe(u8, "feature");
    errdefer allocator.free(head_display);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = full_ref,
                    .display_name = display_name,
                    .kind = .local,
                },
                .head_display = head_display,
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = reviewAppTestOid(base_byte),
                    .head_oid = reviewAppTestOid(head_byte),
                    .diff_base_oid = reviewAppTestOid(base_byte),
                },
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, review_app_test_diff) },
        } },
    };
}

fn reviewAppBasisFailureFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    name: []const u8,
) !ReviewLoadFinished {
    const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    errdefer allocator.free(full_ref);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .basis_failed = .{
            .kind = .missing_base_ref,
            .attempted = .{
                .full_ref = full_ref,
                .display_name = try allocator.dupe(u8, name),
                .kind = .local,
            },
        } },
    };
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

const BranchListItemSpec = struct {
    name: []const u8,
    oid: []const u8,
    current: bool = false,
};

fn branchListForTest(allocator: std.mem.Allocator, specs: []const BranchListItemSpec) !app_load.BranchListLoadTaskResult {
    const items = try allocator.alloc(git_refs.BranchListItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
    }
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

fn abandonSingleQueuedTask(ctx: *chasen.Ctx(TestApp.Msg), allocator: std.mem.Allocator) !void {
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

fn abandonQueuedTasks(ctx: *chasen.Ctx(TestApp.Msg), allocator: std.mem.Allocator) usize {
    const queued = ctx.takePendingTasksWith();
    for (queued) |task| {
        var abandoned = task.failed(task.ctx, .runtime_abandoned, allocator);
        abandoned.deinitUndelivered(allocator);
    }
    return queued.len;
}

fn clearPendingStatusAndDiffTasks(ctx: *chasen.Ctx(TestApp.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}
