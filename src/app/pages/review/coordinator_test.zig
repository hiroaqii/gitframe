//! Owner-local tests for Review coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_root = @import("../../../app.zig");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const diff_basis = @import("../../diff_basis.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const app_test_support = @import("../../test_support.zig");
const context = @import("../../../context.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
const git_review = @import("../../../git/committed_review.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const git_refs = @import("../../../git/refs.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const committed_review = @import("../../../committed_review.zig");
const review_store = @import("../../../review_store.zig");
const review_page = @import("../review.zig");
const review_coordinator = @import("coordinator.zig");
const finding_card_view = @import("finding_card_view.zig");
const review_input = @import("input.zig");
const review_navigation = @import("navigation.zig");
const review_view = @import("view.zig");
const human_review_decision = @import("human_review_decision.zig");
const human_review_session = @import("../../human_review_session.zig");

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
    store: ?review_store.ConfiguredStore = null,
    sessions: human_review_session.Owner = .{},

    const Msg = app_message.Msg;

    fn controller(self: *TestApp) review_coordinator.Controller {
        return .{
            .page_state = &self.pages.review,
            .repo = self.repo_session.view(),
            .layout = self.layout,
            .env_map = null,
            .store = if (self.store) |*value| value else null,
            .sessions = &self.sessions,
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
        .store = try review_store.ConfiguredStore.initConfigured(allocator, "/captured-ai-review-store"),
    };
    defer app.store.?.deinit(allocator);
    defer app.sessions.deinit();
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
    const rows = try allocator.alloc(review_store.RunSummary, 1);
    rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    app.pages.review.ai_reviews.scan_result = .{ .history = .{
        .snapshot = undefined,
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.Diagnostic, 0),
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
    const refreshed_rows = try allocator.alloc(review_store.RunSummary, 1);
    refreshed_rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    try app.update(.{ .load_finished = .{ .review = .{ .history_scan = .{
        .identity = scan_identity,
        .generation = scan_generation,
        .store_identity = app.store.?.identity(),
        .result = .{ .scanned = .{ .history = .{
            .snapshot = undefined,
            .rows = refreshed_rows,
            .diagnostics = try allocator.alloc(review_store.Diagnostic, 0),
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

test "human review result pinned acceptance retires in-flight and deferred ordinary Review refreshes" {
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
    defer app.sessions.deinit();
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
    defer app.sessions.deinit();
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
    defer app.sessions.deinit();
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
    defer app.sessions.deinit();
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
        defer app.sessions.deinit();
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
    defer app.sessions.deinit();
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
    defer app.sessions.deinit();
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
) !review_store.RunSummary {
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
        .store = try review_store.ConfiguredStore.initConfigured(allocator, store_root),
    };
    defer app.store.?.deinit(allocator);
    defer app.sessions.deinit();
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

    const repository_id = try committed_review.ReviewRepositoryId.parse("723e4567-e89b-42d3-a456-426614174000");
    const store_snapshot: review_store.StoreSnapshot = .{
        .root_device = 101,
        .root_inode = 103,
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
        false,
    );
    var bundle_owned = true;
    defer if (bundle_owned) pinned_bundle.deinit(allocator);

    const rows = try allocator.alloc(review_store.RunSummary, 1);
    rows[0] = try reviewHistoryRow(allocator, review_id, .available);
    rows[0].target = pinned_target;
    rows[0].status = .new;
    rows[0].finding_count = 0;
    rows[0].artifact_snapshot = review_store.ArtifactSnapshot.fromLoaded(&pinned_bundle.selection.artifacts);
    app.pages.review.ai_reviews.scan_result = .{ .history = .{
        .snapshot = store_snapshot,
        .rows = rows,
        .diagnostics = try allocator.alloc(review_store.Diagnostic, 0),
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

    const stale_bundle = try reviewHistoryPinnedBundle(
        allocator,
        store_snapshot,
        repository_id,
        review_id,
        pinned_target,
        true,
    );
    try std.testing.expectEqual(@as(usize, 1), stale_bundle.selection.finding_projection.entries.len);
    try app.update(.{ .load_finished = .{ .review = .{ .history_selection = .{
        .identity = selection_identity,
        .generation = selection_generation -% 1,
        .store_identity = app.store.?.identity(),
        .review_id = review_id,
        .result = .{ .loaded = stale_bundle },
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.ai_reviews.phase == .selection_loading);

    bundle_owned = false;
    try app.update(.{ .load_finished = .{ .review = .{ .history_selection = .{
        .identity = selection_identity,
        .generation = selection_generation,
        .store_identity = app.store.?.identity(),
        .review_id = review_id,
        .result = .{ .loaded = pinned_bundle },
    } } } }, &ctx);
    try std.testing.expect(app.pages.review.isPinnedAi());
    const pinned_revision = app.pages.review.source_session_revision;
    try std.testing.expectEqual(normal_revision +% 1, pinned_revision);
    try std.testing.expect(app.pages.review.activeAiReviewId().?.eql(review_id));
    try std.testing.expect(app.pages.review.pinnedAiConst().?.target().eql(&pinned_target));
    const owned_session = app.sessions.currentSessionConst().?;
    try std.testing.expect(owned_session.binding.review_id.eql(review_id));
    try std.testing.expect(owned_session.binding.review_repository_id.eql(repository_id));
    try std.testing.expectEqual(human_review_session.Lifecycle.editable, owned_session.lifecycle());
    const editable_presentation = app.sessions.currentPresentation().?;
    try expectHumanReviewActionLabels(
        &app.pages.review,
        editable_presentation,
        repo_root,
        app.repo_session.repo_epoch,
        app.repo_session.repo_state.root.?.identity,
    );

    try std.testing.expect((try updateHumanReviewDecision(
        &app,
        &ctx,
        .open_human_review_decision,
    )) == null);
    try std.testing.expect(app.pages.review.human_review_decision.isOpen());
    try std.testing.expect(app.pages.review.human_review_decision.selectedDecision() == null);
    try expectHumanReviewDecisionSurfaces(
        &app.pages.review,
        editable_presentation,
        repo_root,
        app.repo_session.repo_epoch,
        app.repo_session.repo_state.root.?.identity,
    );

    {
        var missing_session = app.sessions.current.?;
        app.sessions.current = null;
        defer if (app.sessions.current == null) {
            app.sessions.current = missing_session;
            missing_session = undefined;
        };
        try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .focus_next })) == null);
        try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .{
            .summary_paste = "must not escape to the background",
        } })) == null);
        try std.testing.expect(app.pages.review.human_review_decision.isOpen());
        try std.testing.expectEqual(
            human_review_decision.Feedback.binding_unavailable,
            app.pages.review.human_review_decision.feedback(),
        );
        try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .close })) == null);
        try std.testing.expect(!app.pages.review.human_review_decision.isOpen());
        app.sessions.current = missing_session;
        missing_session = undefined;
    }

    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .open_human_review_decision)) == null);
    {
        const original_review_id = app.sessions.current.?.binding.review_id;
        app.sessions.current.?.binding.review_id.bytes[15] +%= 1;
        defer app.sessions.current.?.binding.review_id = original_review_id;
        try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .activate })) == null);
        try std.testing.expect(app.pages.review.human_review_decision.isOpen());
        try std.testing.expectEqual(
            human_review_decision.Feedback.binding_unavailable,
            app.pages.review.human_review_decision.feedback(),
        );
        try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .close })) == null);
        try std.testing.expect(!app.pages.review.human_review_decision.isOpen());
    }
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .open_human_review_decision)) == null);

    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .focus_next })) == null);
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .activate })) == null);
    try std.testing.expectEqual(
        committed_review.ReviewResultValue.needs_changes,
        app.pages.review.human_review_decision.selectedDecision().?,
    );
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .focus_previous })) == null);
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .focus_previous })) == null);
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .activate })) == null);
    try std.testing.expectEqual(
        human_review_decision.Feedback.needs_changes_evidence_required,
        app.pages.review.human_review_decision.feedback(),
    );
    try std.testing.expectEqual(human_review_decision.Focus.summary, app.pages.review.human_review_decision.focus().?);
    try expectHumanReviewLifecycleSurface(
        &app.pages.review,
        editable_presentation,
        repo_root,
        app.repo_session.repo_epoch,
        app.repo_session.repo_state.root.?.identity,
        .{ .width = 56, .height = 16 },
        &.{ "[x] Needs changes", "Needs changes requires", "> Summary" },
        &.{},
    );
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .{
        .summary_paste = "Evidence from the human reviewer",
    } })) == null);
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .focus_next })) == null);
    try std.testing.expectEqual(
        committed_review.ReviewResultValue.needs_changes,
        (try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .activate })).?,
    );
    try std.testing.expectEqualStrings(
        "Evidence from the human reviewer",
        app.sessions.currentSessionConst().?.workingSnapshot().?.summary.?,
    );
    try std.testing.expect((try updateHumanReviewDecision(&app, &ctx, .{ .human_review_decision = .close })) == null);
    try std.testing.expect(!app.pages.review.human_review_decision.isOpen());

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

fn updateHumanReviewDecision(
    app: *TestApp,
    ctx: *chasen.Ctx(TestApp.Msg),
    msg: @import("input.zig").Msg,
) !?committed_review.ReviewResultValue {
    var outcome = try app.controller().update(ctx, msg);
    defer outcome.deinit(ctx.allocator());
    return outcome.takeHumanReviewFinalize();
}

fn expectHumanReviewDecisionSurfaces(
    page_state: *review_page.ReviewPageState,
    editable: human_review_session.Presentation,
    repo_root: []const u8,
    repo_epoch: u64,
    root_identity: repo_root_capability.Identity,
) !void {
    const sizes = [_]chasen.Size{
        .{ .width = 120, .height = 32 },
        .{ .width = 80, .height = 24 },
        .{ .width = 56, .height = 16 },
    };
    for (sizes) |size| {
        var surface: chasen.testing.TestSurface = undefined;
        try surface.init(size.width, size.height);
        defer surface.deinit();
        try review_view.viewHumanReviewDecision(.{
            .page = page_state,
            .human_review = editable,
            .palette = .default(),
            .repo_root = repo_root,
            .repo_epoch = repo_epoch,
            .root_identity = root_identity,
            .layout = .{ .width = size.width, .height = size.height },
        }, &surface.surface);
        const snapshot = try surface.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Finalize human review") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Approved") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Needs changes") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Canceled") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "[x]") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc/q: close") != null);
    }

    var finalizing = editable;
    finalizing.lifecycle = .finalizing;
    try expectHumanReviewLifecycleSurface(
        page_state,
        finalizing,
        repo_root,
        repo_epoch,
        root_identity,
        .{ .width = 56, .height = 16 },
        &.{ "Completing review result", "Run ", "Summary (read-only)", "Completing continues" },
        &.{"[ Submit ]"},
    );

    var saving = editable;
    saving.lifecycle = .saving;
    page_state.human_review_decision.markFinalizeRejected(.capacity);
    try expectHumanReviewLifecycleSurface(
        page_state,
        saving,
        repo_root,
        repo_epoch,
        root_identity,
        .{ .width = 56, .height = 16 },
        &.{ "Saving review draft", "Run ", "Summary (read-only)", "Completing continues" },
        &.{ "[ Submit ]", "capacity" },
    );

    var long_snapshot = try human_review_session.DraftSnapshot.init(
        std.testing.allocator,
        "長い人間レビュー要約 👩‍🚀 e\u{301}\nsecond line remains exact",
        if (editable.snapshot) |snapshot| snapshot.finding_dispositions else &.{},
        if (editable.snapshot) |snapshot| snapshot.anchored_notes else &.{},
    );
    defer long_snapshot.deinit();
    var completed_at = "2026-08-27T12:00:00Z".*;
    var completed = editable;
    completed.lifecycle = .completed;
    completed.decision = .approved;
    completed.completed_at = &completed_at;
    completed.snapshot = &long_snapshot;
    page_state.human_review_decision.markFinalizeAccepted();
    for ([_]chasen.Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 56, .height = 16 },
    }) |size| try expectHumanReviewLifecycleSurface(
        page_state,
        completed,
        repo_root,
        repo_epoch,
        root_identity,
        size,
        &.{ "Human review result", "Completed at 2026-08-27T12:00:00Z", "Run ", "[x] Approved", "Summary (read-only)", "👩‍🚀", "second line remains exact" },
        &.{"Completing review..."},
    );
    try page_state.human_review_decision.open(std.testing.allocator, editable);

    var failed = editable;
    failed.lifecycle = .failed;
    try expectHumanReviewLifecycleSurface(
        page_state,
        failed,
        repo_root,
        repo_epoch,
        root_identity,
        .{ .width = 80, .height = 24 },
        &.{ "Completion failed", "preserved form remains available for retry", "[ Submit ]" },
        &.{},
    );

    var reload_required = failed;
    reload_required.reconciliation = .reload_required;
    try expectHumanReviewLifecycleSurface(
        page_state,
        reload_required,
        repo_root,
        repo_epoch,
        root_identity,
        .{ .width = 56, .height = 16 },
        &.{ "Review state requires reload", "Summary (read-only)", "Reload the pinned Review" },
        &.{"[ Submit ]"},
    );
}

fn expectHumanReviewActionLabels(
    page_state: *const review_page.ReviewPageState,
    editable: human_review_session.Presentation,
    repo_root: []const u8,
    repo_epoch: u64,
    root_identity: repo_root_capability.Identity,
) !void {
    const base_context: review_view.Context = .{
        .page = page_state,
        .human_review = editable,
        .palette = .default(),
        .repo_root = repo_root,
        .repo_epoch = repo_epoch,
        .root_identity = root_identity,
        .layout = .{ .width = 80, .height = 24 },
    };
    try std.testing.expectEqualStrings("finalize", review_view.humanReviewActionLabel(base_context).?);
    var missing = base_context;
    missing.human_review = null;
    try std.testing.expect(review_view.humanReviewActionLabel(missing) == null);
    var mismatched_presentation = editable;
    mismatched_presentation.binding.review_id.bytes[15] +%= 1;
    var mismatched = base_context;
    mismatched.human_review = mismatched_presentation;
    try std.testing.expect(review_view.humanReviewActionLabel(mismatched) == null);
    var completed = editable;
    completed.lifecycle = .completed;
    var completed_context = base_context;
    completed_context.human_review = completed;
    try std.testing.expectEqualStrings("result", review_view.humanReviewActionLabel(completed_context).?);
    var saving = editable;
    saving.lifecycle = .saving;
    var saving_context = base_context;
    saving_context.human_review = saving;
    try std.testing.expectEqualStrings("result", review_view.humanReviewActionLabel(saving_context).?);
}

fn expectHumanReviewLifecycleSurface(
    page_state: *const review_page.ReviewPageState,
    presentation: human_review_session.Presentation,
    repo_root: []const u8,
    repo_epoch: u64,
    root_identity: repo_root_capability.Identity,
    size: chasen.Size,
    expected: []const []const u8,
    forbidden: []const []const u8,
) !void {
    var surface: chasen.testing.TestSurface = undefined;
    try surface.init(size.width, size.height);
    defer surface.deinit();
    try review_view.viewHumanReviewDecision(.{
        .page = page_state,
        .human_review = presentation,
        .palette = .default(),
        .repo_root = repo_root,
        .repo_epoch = repo_epoch,
        .root_identity = root_identity,
        .layout = .{ .width = size.width, .height = size.height },
    }, &surface.surface);
    const snapshot = try surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    for (expected) |text| {
        if (std.mem.indexOf(u8, snapshot, text) == null) {
            std.debug.print("missing renderer text {s} at {d}x{d}:\n{s}\n", .{ text, size.width, size.height, snapshot });
            return error.TestUnexpectedResult;
        }
    }
    for (forbidden) |text| try std.testing.expect(std.mem.indexOf(u8, snapshot, text) == null);
}

test "Review inline Finding owner and fold mode file lifecycle use the accepted projection" {
    const allocator = std.testing.allocator;
    const repository_id = try committed_review.ReviewRepositoryId.parse("a23e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed_review.ReviewId.parse("b23e4567-e89b-42d3-a456-426614174000");
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = reviewAppTestOid('a'),
        .head_oid = reviewAppTestOid('b'),
        .diff_base_oid = reviewAppTestOid('a'),
    };
    const snapshot: review_store.StoreSnapshot = .{
        .root_device = 1,
        .root_inode = 2,
        .repository_locator = .{ .device = 3, .inode = 4 },
        .review_repository_id = repository_id,
    };
    var bundle = try reviewHistoryPinnedBundle(allocator, snapshot, repository_id, review_id, target, true);
    try std.testing.expectEqual(@as(usize, 1), bundle.selection.finding_projection.summary.mapped);

    var folded_hunks = [_]bool{ false, false };
    var loaded = app_test_support.loadedDiffTwo();
    loaded.collapsed_hunks = &folded_hunks;
    var finding_presentation_cache = try review_page.FindingPresentationCache.init(
        allocator,
        &bundle.selection,
        loaded.lines,
    );
    errdefer if (finding_presentation_cache) |*cache| cache.deinit(allocator);
    var page_state: review_page.ReviewPageState = .{
        .load = app_test_support.loadState(loaded),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_node = 0,
            .focus = .diff,
            .sidebar_hidden = true,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } },
            .display_mode = .unified,
        },
        .presentation = .{ .pinned_ai = .{
            .selection = bundle.selection,
            .base_display = try allocator.dupe(u8, "base"),
            .head_display = try allocator.dupe(u8, "head"),
            .finding_presentation_cache = finding_presentation_cache,
        } },
    };
    finding_presentation_cache = null;
    bundle.selection = undefined;
    defer page_state.deinit(allocator);

    const model = finding_card.FindingCardModel.init(&page_state.pinnedAiConst().?.selection.finding_projection, 0).?;
    page_state.viewer.diff_cursor = .{ .hunk_line = .{
        .hunk_index = model.span.hunk_ordinal,
        .line_index = model.span.last_diff_line_ordinal,
    } };
    _ = page_state.finding_card.apply(.{ .focus = model });
    const unified_view: review_navigation.View = .{
        .page = &page_state,
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 100, .height = 30 },
    };
    try std.testing.expect(unified_view.findingCardAtCursor());
    try std.testing.expect(unified_view.focusedFindingCardVisible());
    var frame = (try unified_view.buildFindingCardFrame(allocator)).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), frame.row_plan.cards.len);

    var foreign = model;
    foreign.identity.findings_digest.bytes[0] ^= 0xff;
    try std.testing.expect(review_page.findingCardContent(&page_state.pinnedAiConst().?.selection, foreign) == null);

    var repository: repo_session.State = .{};
    var sessions: human_review_session.Owner = .{};
    defer sessions.deinit();
    const controller: review_coordinator.Controller = .{
        .page_state = &page_state,
        .repo = repository.view(),
        .layout = .{ .width = 100, .height = 30 },
        .env_map = null,
        .sessions = &sessions,
    };

    switch (page_state.load.state) {
        .loaded => |*session| session.loaded.setHunkFolded(0, model.span.hunk_ordinal, true),
        else => unreachable,
    }
    controller.reconcileFindingCardVisibility();
    try std.testing.expect(!page_state.finding_card.isFocused());

    switch (page_state.load.state) {
        .loaded => |*session| session.loaded.setHunkFolded(0, model.span.hunk_ordinal, false),
        else => unreachable,
    }
    _ = page_state.finding_card.apply(.{ .focus = model });
    page_state.viewer.display_mode = .side_by_side;
    controller.reconcileFindingCardVisibility();
    try std.testing.expect(page_state.finding_card.isFocused());
    var side_frame = (try controller.navigationView().buildFindingCardFrame(allocator)).?;
    defer side_frame.deinit(allocator);
    try std.testing.expectEqual(diff_render.InlineBlockPlacement.new, side_frame.presentation_rows.blocks[0].placement);

    var narrow_controller = controller;
    narrow_controller.layout.width = 40;
    narrow_controller.reconcileFindingCardVisibility();
    try std.testing.expect(page_state.finding_card.isFocused());

    page_state.viewer.display_mode = .unified;
    page_state.viewer.selected_target = .{ .diff_file = 1 };
    page_state.viewer.selected_node = 1;
    controller.reconcileFindingCardVisibility();
    try std.testing.expect(!page_state.finding_card.isFocused());

    page_state.pinnedAi().?.selection.finding_projection.entries[0].outcome = .{ .stale = .range_out_of_bounds };
    try std.testing.expect(page_state.contentForFindingCard(model) == null);
}

test "Review shared display-mode and terminal resize prepare Finding cards before mutation" {
    const allocator = std.testing.allocator;
    const repository_id = try committed_review.ReviewRepositoryId.parse("c23e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed_review.ReviewId.parse("d23e4567-e89b-42d3-a456-426614174000");
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = reviewAppTestOid('a'),
        .head_oid = reviewAppTestOid('b'),
        .diff_base_oid = reviewAppTestOid('a'),
    };
    const snapshot: review_store.StoreSnapshot = .{
        .root_device = 1,
        .root_inode = 2,
        .repository_locator = .{ .device = 3, .inode = 4 },
        .review_repository_id = repository_id,
    };
    var bundle = try reviewHistoryPinnedBundle(allocator, snapshot, repository_id, review_id, target, true);
    bundle.selection.finding_projection.entries[0].outcome = .{ .mapped = .{
        .file_ordinal = 0,
        .hunk_ordinal = 0,
        .first_diff_line_ordinal = 0,
        .last_diff_line_ordinal = 0,
    } };

    var folded_hunks = [_]bool{false};
    var loaded = app_test_support.loadedDiffWide();
    loaded.collapsed_hunks = &folded_hunks;
    var finding_presentation_cache = try review_page.FindingPresentationCache.init(
        allocator,
        &bundle.selection,
        loaded.lines,
    );
    errdefer if (finding_presentation_cache) |*cache| cache.deinit(allocator);
    var page_state: review_page.ReviewPageState = .{
        .load = app_test_support.loadState(loaded),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_node = 0,
            .focus = .diff,
            .sidebar_hidden = true,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            .display_mode = .unified,
        },
        .presentation = .{ .pinned_ai = .{
            .selection = bundle.selection,
            .base_display = try allocator.dupe(u8, "base"),
            .head_display = try allocator.dupe(u8, "head"),
            .finding_presentation_cache = finding_presentation_cache,
        } },
    };
    finding_presentation_cache = null;
    bundle.selection = undefined;
    var page_state_owned = true;
    defer if (page_state_owned) page_state.deinit(allocator);

    var repository: repo_session.State = .{};
    var sessions: human_review_session.Owner = .{};
    defer sessions.deinit();
    const controller: review_coordinator.Controller = .{
        .page_state = &page_state,
        .repo = repository.view(),
        .layout = .{ .width = 140, .height = 4 },
        .env_map = null,
        .sessions = &sessions,
    };
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    const retained_source_line_bound = page_state.load.state.loaded.loaded.lines;
    page_state.load.state.loaded.loaded.lines = std.math.maxInt(usize);
    try std.testing.expectError(
        error.InvalidFindingCardPreparation,
        controller.navigationView().prepareFindingCardFrame(allocator),
    );
    page_state.load.state.loaded.loaded.lines = retained_source_line_bound;

    const failure_model = finding_card.FindingCardModel.init(
        &page_state.pinnedAiConst().?.selection.finding_projection,
        0,
    ).?;
    page_state.viewer.display_mode = .side_by_side;
    page_state.viewer.diff_scroll = 1;
    page_state.selection_layout_revision = 17;
    _ = page_state.finding_card.apply(.{ .focus = failure_model });
    var fill_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = review_navigation.FindingCardFramePreparation.allocation_count,
    });
    var fill_preparation = (try controller.navigationView().prepareFindingCardFrame(fill_allocator.allocator())).?;
    defer fill_preparation.deinit();
    try std.testing.expect(!fill_allocator.has_induced_failure);
    try std.testing.expect(fill_preparation.fill(controller.navigationView(), page_state.finding_card) != null);
    try std.testing.expect(!fill_allocator.has_induced_failure);
    page_state.selection_owner = .{ .diff = diff_selection.DragSelection.init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    const owner_before = page_state.selection_owner;
    const card_before = page_state.finding_card;
    const target_before = page_state.viewer.selected_target;
    const cursor_before = page_state.viewer.diff_cursor;
    const display_before = page_state.review_display;
    var semantic_before_adapter = controller.navigation().updateAdapter();
    const semantic_before = semantic_before_adapter.bodyController().view().selectedCoordinateAtOffset(1);
    for (0..review_navigation.FindingCardFramePreparation.allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var failing_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = failing.allocator() };
        try std.testing.expectError(error.OutOfMemory, controller.update(&failing_ctx, .{ .shared = .toggle_display_mode }));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, page_state.viewer.display_mode);
        try std.testing.expectEqual(@as(usize, 1), page_state.viewer.diff_scroll);
        try std.testing.expectEqual(@as(u64, 17), page_state.selection_layout_revision);
        try std.testing.expectEqualDeep(owner_before, page_state.selection_owner);
        try std.testing.expectEqualDeep(card_before, page_state.finding_card);
        try std.testing.expectEqualDeep(target_before, page_state.viewer.selected_target);
        try std.testing.expectEqualDeep(cursor_before, page_state.viewer.diff_cursor);
        try std.testing.expectEqualDeep(display_before, page_state.review_display);
        try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, controller.navigationView().view().effectiveDisplayMode());
        var semantic_after_adapter = controller.navigation().updateAdapter();
        try std.testing.expectEqualDeep(semantic_before, semantic_after_adapter.bodyController().view().selectedCoordinateAtOffset(1));
        try std.testing.expect(!folded_hunks[0] and page_state.completed_selection == null and page_state.pinned_selection_basis == null);
    }
    var prepared_success = try controller.update(&ctx, .{ .shared = .toggle_display_mode });
    prepared_success.deinit(allocator);
    page_state.selection_owner = .none;
    page_state.finding_card = .unfocused;
    page_state.viewer.diff_scroll = 0;

    var frame = (try controller.navigationView().buildFindingCardFrame(allocator)).?;
    try std.testing.expect(page_state.selection_owner == .none);
    try std.testing.expect(!page_state.finding_card.isFocused());
    try std.testing.expectEqual(@as(usize, 2), frame.presentation_rows.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), frame.presentation_rows.blocks[0].height);
    const source_anchor = frame.presentation_rows.blocks[0].after_source_offset;
    const raw_tops = [_]usize{
        frame.presentation_rows.blocks[0].presentation_start,
        frame.presentation_rows.blocks[1].presentation_start,
    };
    var unified_controller = controller.navigation();
    unified_controller.presentation_rows = &frame.presentation_rows;
    var unified_adapter = unified_controller.updateAdapter();
    const unified_body = unified_adapter.bodyController();
    const source_rows = unified_body.view().sourceDiffLineCount();
    const semantic_anchor = unified_body.view().selectedCoordinateAtOffset(source_anchor).?;
    const source_cursor = page_state.viewer.diff_cursor;
    frame.deinit(allocator);

    for (raw_tops) |raw_top| {
        page_state.viewer.display_mode = .unified;
        page_state.viewer.diff_scroll = raw_top;
        var to_side = try controller.update(&ctx, .{ .shared = .toggle_display_mode });
        to_side.deinit(allocator);

        var side_adapter = controller.navigation().updateAdapter();
        const side_body = side_adapter.bodyController();
        try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, side_body.view().view.effectiveDisplayMode());
        try std.testing.expectEqual(source_rows, side_body.view().sourceDiffLineCount());
        try std.testing.expectEqualDeep(semantic_anchor, side_body.view().selectedCoordinateAtOffset(page_state.viewer.diff_scroll).?);
        try std.testing.expectEqualDeep(source_cursor, page_state.viewer.diff_cursor);

        var to_unified = try controller.update(&ctx, .{ .shared = .toggle_display_mode });
        to_unified.deinit(allocator);
        var fresh = (try controller.navigationView().buildFindingCardFrame(allocator)).?;
        defer fresh.deinit(allocator);
        var fresh_controller = controller.navigation();
        fresh_controller.presentation_rows = &fresh.presentation_rows;
        var fresh_adapter = fresh_controller.updateAdapter();
        const fresh_body = fresh_adapter.bodyController();
        try std.testing.expectEqual(source_anchor, fresh_body.view().sourceAnchorAtOrBeforePresentation(page_state.viewer.diff_scroll).?);
        try std.testing.expectEqual(fresh.presentation_rows.sourceToPresentation(source_anchor).?, page_state.viewer.diff_scroll);
        try std.testing.expectEqualDeep(source_cursor, page_state.viewer.diff_cursor);
    }

    var narrow_controller = controller;
    narrow_controller.layout.width = 40;
    page_state.viewer.diff_scroll = raw_tops[0];
    var effective_unified = try narrow_controller.update(&ctx, .{ .shared = .toggle_display_mode });
    effective_unified.deinit(allocator);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, narrow_controller.navigationView().view().effectiveDisplayMode());
    try std.testing.expectEqual(raw_tops[0], page_state.viewer.diff_scroll);

    var root_app: app_root.App = .{ .active_page = .review, .terminal_size = .{ .width = 140, .height = 12 } };
    root_app.pages.review = page_state;
    page_state_owned = false;
    defer root_app.pages.review.deinit(allocator);
    root_app.pages.review.viewer.display_mode = .side_by_side;
    root_app.pages.review.viewer.diff_scroll = 1;
    _ = root_app.pages.review.finding_card.apply(.{ .focus = failure_model });
    root_app.pages.review.selection_owner = .{ .diff = diff_selection.DragSelection.init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    root_app.drag_auto_scroll.active = .{
        .generation = 9,
        .target = .review,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 5, .row = 10 } },
    };
    root_app.drag_auto_scroll.scheduled_generation = 9;
    const resize_owner_before = root_app.pages.review.selection_owner;
    const resize_card_before = root_app.pages.review.finding_card;
    const resize_layout_before = root_app.pages.review.selection_layout_revision;
    const resize_cursor_before = root_app.pages.review.viewer.diff_cursor;
    for (0..review_navigation.FindingCardFramePreparation.allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        root_app.allocator = failing.allocator();
        var failing_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = failing.allocator() };
        try std.testing.expectError(error.OutOfMemory, root_app.update(.{ .terminal_resized = .{ .width = 40, .height = 12 } }, &failing_ctx));
        root_app.allocator = allocator;
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(chasen.Size{ .width = 140, .height = 12 }, root_app.terminal_size);
        try std.testing.expectEqualDeep(resize_owner_before, root_app.pages.review.selection_owner);
        try std.testing.expect(root_app.drag_auto_scroll.active != null and root_app.drag_auto_scroll.scheduled_generation == 9);
        try std.testing.expectEqual(@as(usize, 1), root_app.pages.review.viewer.diff_scroll);
        try std.testing.expectEqualDeep(resize_card_before, root_app.pages.review.finding_card);
        try std.testing.expectEqual(resize_layout_before, root_app.pages.review.selection_layout_revision);
        try std.testing.expectEqualDeep(resize_cursor_before, root_app.pages.review.viewer.diff_cursor);
    }
    root_app.drag_auto_scroll.scheduled_generation = null;
    try root_app.update(.{ .terminal_resized = .{ .width = 40, .height = 12 } }, &ctx);
    try std.testing.expectEqual(chasen.Size{ .width = 40, .height = 12 }, root_app.terminal_size);
    try std.testing.expect(root_app.pages.review.selection_owner == .none and root_app.drag_auto_scroll.active == null);
}

test "Finding navigation cycles projection order lands exact source and unfolds only its target" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 12 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    const projection = &harness.page_state.pinnedAi().?.selection.finding_projection;
    try std.testing.expectEqual(@as(usize, 4), projection.files[0].mapped_entry_indices.len);
    try std.testing.expectEqual(@as(usize, 5), projection.mapped_entry_indices.len);
    const current_order = projection.files[0].mapped_entry_indices;

    for (current_order) |entry_index| {
        try harness.navigate(allocator, layout, .current_file, .next);
        try expectFindingNavigationTarget(&harness, layout, entry_index);
    }
    try harness.navigate(allocator, layout, .current_file, .next);
    try expectFindingNavigationTarget(&harness, layout, current_order[0]);
    harness.page_state.finding_card = .unfocused;
    try harness.navigate(allocator, layout, .current_file, .previous);
    try expectFindingNavigationTarget(&harness, layout, current_order[current_order.len - 1]);

    const original_current_order = projection.files[0].mapped_entry_indices;
    projection.files[0].mapped_entry_indices = original_current_order[1..2];
    const one_model = finding_card.FindingCardModel.init(projection, original_current_order[1]).?;
    _ = harness.page_state.finding_card.apply(.{ .focus = one_model });
    _ = harness.page_state.finding_card.apply(.toggle);
    const one_revision = harness.page_state.selection_layout_revision;
    try harness.navigate(allocator, layout, .current_file, .next);
    try expectFindingNavigationTarget(&harness, layout, original_current_order[1]);
    try std.testing.expectEqual(one_revision + 1, harness.page_state.selection_layout_revision);
    projection.files[0].mapped_entry_indices = original_current_order;

    const viewer_before_zero = harness.page_state.viewer;
    const card_before_zero = harness.page_state.finding_card;
    const revision_before_zero = harness.page_state.selection_layout_revision;
    projection.files[0].mapped_entry_indices = &.{};
    try harness.navigate(allocator, layout, .current_file, .next);
    try std.testing.expectEqualStrings("No mapped Findings in this file", harness.page_state.status.text());
    try std.testing.expectEqualDeep(viewer_before_zero, harness.page_state.viewer);
    try std.testing.expectEqualDeep(card_before_zero, harness.page_state.finding_card);
    try std.testing.expectEqual(revision_before_zero, harness.page_state.selection_layout_revision);
    projection.files[0].mapped_entry_indices = original_current_order;

    const invalid_entry = original_current_order[0];
    const valid_outcome = projection.entries[invalid_entry].outcome;
    projection.entries[invalid_entry].outcome = .{ .mapped = .{
        .file_ordinal = 0,
        .hunk_ordinal = 0,
        .first_diff_line_ordinal = 0,
        .last_diff_line_ordinal = 999,
    } };
    harness.page_state.finding_card = .unfocused;
    const viewer_before_invalid = harness.page_state.viewer;
    try harness.navigate(allocator, layout, .current_file, .next);
    try std.testing.expectEqualStrings("Finding target is unavailable", harness.page_state.status.text());
    try std.testing.expectEqualDeep(viewer_before_invalid, harness.page_state.viewer);
    try std.testing.expect(!harness.page_state.finding_card.isFocused());
    projection.entries[invalid_entry].outcome = valid_outcome;

    const beta_entry = projection.mapped_entry_indices[projection.mapped_entry_indices.len - 1];
    projection.files[0].mapped_entry_indices = projection.mapped_entry_indices[projection.mapped_entry_indices.len - 1 ..];
    harness.page_state.finding_card = .unfocused;
    const viewer_before_wrong_file = harness.page_state.viewer;
    try harness.navigate(allocator, layout, .current_file, .next);
    try std.testing.expectEqualStrings("Finding target is unavailable", harness.page_state.status.text());
    try std.testing.expectEqualDeep(viewer_before_wrong_file, harness.page_state.viewer);
    try std.testing.expect(!harness.page_state.finding_card.isFocused());
    try std.testing.expectEqual(@as(usize, 1), finding_card.FindingCardModel.init(projection, beta_entry).?.span.file_ordinal);
    projection.files[0].mapped_entry_indices = original_current_order;

    const original_beta_order = projection.files[1].mapped_entry_indices;
    projection.files[1].mapped_entry_indices = &.{};
    const viewer_before_missing_file_entry = harness.page_state.viewer;
    try harness.navigate(allocator, layout, .all_files, .previous);
    try std.testing.expectEqualStrings("Finding target is unavailable", harness.page_state.status.text());
    try std.testing.expectEqualDeep(viewer_before_missing_file_entry, harness.page_state.viewer);
    try std.testing.expect(!harness.page_state.finding_card.isFocused());
    projection.files[1].mapped_entry_indices = original_beta_order;

    const loaded = harness.loaded();
    loaded.setHunkFolded(0, 0, true);
    loaded.setHunkFolded(0, 1, true);
    harness.page_state.finding_card = .unfocused;
    const unfold_revision = harness.page_state.selection_layout_revision;
    try harness.navigate(allocator, layout, .current_file, .previous);
    try expectFindingNavigationTarget(&harness, layout, current_order[current_order.len - 1]);
    try std.testing.expect(loaded.isHunkFolded(0, 0));
    try std.testing.expect(!loaded.isHunkFolded(0, 1));
    try std.testing.expectEqual(unfold_revision + 1, harness.page_state.selection_layout_revision);
    try std.testing.expectEqual(@as(usize, 0), harness.page_state.status.text().len);

    harness.page_state.finding_card = .unfocused;
    harness.page_state.viewer.selected_target = .{ .diff_file = 0 };
    harness.page_state.viewer.selected_node = loaded.tree.selectedNodeIndex(0).?;
    try harness.navigate(allocator, layout, .all_files, .next);
    try expectFindingNavigationTarget(&harness, layout, projection.mapped_entry_indices[0]);
    harness.page_state.finding_card = .unfocused;
    try harness.navigate(allocator, layout, .all_files, .previous);
    try expectFindingNavigationTarget(&harness, layout, projection.mapped_entry_indices[projection.mapped_entry_indices.len - 1]);
    try std.testing.expectEqual(loaded.tree.selectedNodeIndex(1).?, harness.page_state.viewer.selected_node);
    try harness.navigate(allocator, layout, .all_files, .next);
    try expectFindingNavigationTarget(&harness, layout, projection.mapped_entry_indices[0]);
    try harness.navigate(allocator, layout, .all_files, .previous);
    try expectFindingNavigationTarget(&harness, layout, projection.mapped_entry_indices[projection.mapped_entry_indices.len - 1]);

    harness.page_state.viewer.display_mode = .side_by_side;
    try harness.navigate(allocator, .{ .width = 120, .height = 12 }, .all_files, .next);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, harness.controller(.{ .width = 120, .height = 12 }).navigationView().view().effectiveDisplayMode());
    try expectFindingNavigationTarget(&harness, .{ .width = 120, .height = 12 }, projection.mapped_entry_indices[0]);
    const narrow: diff_surface.Layout = .{ .width = 40, .height = 12 };
    try std.testing.expectEqual(diff_render.DisplayMode.unified, harness.controller(narrow).navigationView().view().effectiveDisplayMode());
    try harness.navigate(allocator, narrow, .all_files, .next);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, harness.page_state.viewer.display_mode);
    try expectFindingNavigationTarget(&harness, narrow, projection.mapped_entry_indices[1]);

    const original_global_order = projection.mapped_entry_indices;
    projection.mapped_entry_indices = &.{};
    const viewer_before_global_zero = harness.page_state.viewer;
    try harness.navigate(allocator, narrow, .all_files, .next);
    try std.testing.expectEqualStrings("No mapped Findings in this review", harness.page_state.status.text());
    try std.testing.expectEqualDeep(viewer_before_global_zero, harness.page_state.viewer);
    projection.mapped_entry_indices = original_global_order;
}

test "Finding navigation commits every hidden sidebar scalar terminal and preserves later input semantics" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 12 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    const loaded = harness.loaded();
    const alpha_file = loaded.tree.selectedNodeIndex(0).?;
    const beta_file = loaded.tree.selectedNodeIndex(1).?;
    const source_directory = findingNavigationTreeNode(loaded, .directory, "src").?;
    const beta_directory = findingNavigationTreeNode(loaded, .directory, "src/beta").?;
    const arena_allocator = harness.page_state.load.state.loaded.arena.allocator();

    try file_tree.collapse(arena_allocator, &loaded.collapsed_dirs, "src/beta");
    try loaded.rebuildVisibleNodes(arena_allocator, false, .all);
    resetFindingNavigationSource(&harness, alpha_file);
    try harness.navigate(allocator, layout, .all_files, .previous);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    try std.testing.expectEqual(beta_directory, harness.page_state.viewer.selected_node);
    var adapter = harness.controller(layout).navigation().updateAdapter();
    var body = adapter.bodyController();
    body.selectFileDelta(-1);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);

    resetFindingNavigationSource(&harness, alpha_file);
    try harness.navigate(allocator, layout, .all_files, .previous);
    adapter = harness.controller(layout).navigation().updateAdapter();
    body = adapter.bodyController();
    try body.clickSidebarNode(beta_directory);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    try std.testing.expectEqual(beta_directory, harness.page_state.viewer.selected_node);
    try body.clickSidebarNode(alpha_file);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);

    const filter_cases = [_]struct { filter: loaded_diff.ChangedFileFilter, expected_node: enum { exact, ancestor } }{
        .{ .filter = .all, .expected_node = .exact },
        .{ .filter = .modified, .expected_node = .ancestor },
        .{ .filter = .added, .expected_node = .exact },
        .{ .filter = .deleted, .expected_node = .exact },
        .{ .filter = .renamed, .expected_node = .exact },
        .{ .filter = .binary, .expected_node = .exact },
    };
    for (filter_cases) |case| {
        harness.page_state.review_display.changed_file_filter = case.filter;
        try loaded.rebuildVisibleNodes(arena_allocator, false, case.filter);
        resetFindingNavigationSource(&harness, alpha_file);
        try harness.navigate(allocator, layout, .all_files, .previous);
        try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
        try std.testing.expectEqual(
            if (case.expected_node == .exact) beta_file else source_directory,
            harness.page_state.viewer.selected_node,
        );
        if (case.filter == .deleted or case.filter == .renamed or case.filter == .binary) {
            try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
            var filtered_adapter = harness.controller(layout).navigation().updateAdapter();
            var filtered_body = filtered_adapter.bodyController();
            filtered_body.selectFileDelta(1);
            try std.testing.expectEqual(beta_file, harness.page_state.viewer.selected_node);
            try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
            try std.testing.expect(loaded.sidebarNodeAtBodyRow(beta_file, 8, 0) == null);
        } else if (case.filter == .modified) {
            var filtered_adapter = harness.controller(layout).navigation().updateAdapter();
            var filtered_body = filtered_adapter.bodyController();
            filtered_body.selectFileDelta(1);
            try std.testing.expect(loaded.visibleRowOfNode(harness.page_state.viewer.selected_node) != null);
            try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
            filtered_body.selectFileDelta(1);
            try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);
        }
    }

    harness.page_state.review_display.changed_file_filter = .all;
    harness.page_state.review_display.hide_reviewed_files = true;
    loaded.reviewed_files[1] = true;
    try loaded.rebuildVisibleNodes(arena_allocator, true, .all);
    resetFindingNavigationSource(&harness, alpha_file);
    try harness.navigate(allocator, layout, .all_files, .previous);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    try std.testing.expectEqual(source_directory, harness.page_state.viewer.selected_node);
    adapter = harness.controller(layout).navigation().updateAdapter();
    body = adapter.bodyController();
    body.selectFileDelta(1);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    body.selectFileDelta(1);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);
    loaded.reviewed_files[1] = false;
    harness.page_state.review_display.hide_reviewed_files = false;

    try loaded.rebuildVisibleNodes(arena_allocator, false, .all);
    loaded.visible_nodes[0] = alpha_file;
    loaded.visible_node_count = 1;
    resetFindingNavigationSource(&harness, alpha_file);
    try harness.navigate(allocator, layout, .all_files, .previous);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    try std.testing.expectEqual(alpha_file, harness.page_state.viewer.selected_node);
    adapter = harness.controller(layout).navigation().updateAdapter();
    body = adapter.bodyController();
    body.selectFileDelta(1);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);
    try body.clickSidebarNode(alpha_file);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);

    harness.page_state.review_display.changed_file_filter = .deleted;
    try loaded.rebuildVisibleNodes(arena_allocator, false, .deleted);
    resetFindingNavigationSource(&harness, alpha_file);
    try harness.navigate(allocator, layout, .all_files, .previous);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(beta_file, harness.page_state.viewer.selected_node);
    adapter = harness.controller(layout).navigation().updateAdapter();
    body = adapter.bodyController();
    body.selectFileDelta(-1);
    body.selectFileDelta(1);
    try std.testing.expectEqual(beta_file, harness.page_state.viewer.selected_node);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);

    harness.page_state.review_display.changed_file_filter = .all;
    try loaded.rebuildVisibleNodes(arena_allocator, false, .all);
    body.reconcileSelectionAfterVisibleNodeChange(loaded);
    try std.testing.expectEqual(beta_file, harness.page_state.viewer.selected_node);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 1 }), harness.page_state.viewer.selected_target);

    harness.page_state.review_display.changed_file_filter = .deleted;
    try loaded.rebuildVisibleNodes(arena_allocator, false, .deleted);
    harness.page_state.review_display.changed_file_filter = .modified;
    try loaded.rebuildVisibleNodes(arena_allocator, false, .modified);
    body.reconcileSelectionAfterVisibleNodeChange(loaded);
    try std.testing.expectEqual(alpha_file, harness.page_state.viewer.selected_node);
    try std.testing.expectEqualDeep(@as(?context.SelectedTarget, .{ .diff_file = 0 }), harness.page_state.viewer.selected_target);
}

test "Finding navigation preparation failures preserve complete state and success allocates nothing late" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 8 };
    var first_success: ?usize = null;
    for (0..32) |fail_index| {
        var harness = try FindingNavigationHarness.init(allocator, true);
        defer harness.deinit(allocator);
        const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
        const first = finding_card.FindingCardModel.init(projection, projection.files[0].mapped_entry_indices[0]).?;
        _ = harness.page_state.finding_card.apply(.{ .focus = first });
        _ = harness.page_state.finding_card.apply(.toggle);
        harness.page_state.viewer.diff_scroll = 3;
        harness.page_state.viewer.diff_horizontal_scroll = 2;
        harness.page_state.viewer.sidebar_horizontal_scroll = 1;
        harness.page_state.selection_layout_revision = 41;
        harness.page_state.selection_owner = .{ .diff = diff_selection.DragSelection.init(
            .{ .loaded_file = .{ .file_index = 0, .path_key = "src/alpha/a.zig" } },
            .new,
            .{ .hunk_index = 0, .line_index = 0 },
        ) };
        harness.page_state.search.match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } } };
        harness.page_state.search.match_offset = 4;
        harness.loaded().setHunkFolded(0, 1, true);
        harness.page_state.status.set("older diagnostic", .{});

        const viewer_before = harness.page_state.viewer;
        const card_before = harness.page_state.finding_card;
        const selection_before = harness.page_state.selection_owner;
        const search_before = harness.page_state.search;
        const cache_before = harness.loaded().rendered_line_cache;
        const folds_before = [3]bool{
            harness.loaded().collapsed_hunks[0],
            harness.loaded().collapsed_hunks[1],
            harness.loaded().collapsed_hunks[2],
        };
        const revision_before = harness.page_state.selection_layout_revision;

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = failing.allocator() };
        var outcome = try harness.controller(layout).update(&ctx, .{ .finding_navigation = .{
            .scope = .all_files,
            .direction = .previous,
        } });
        outcome.deinit(failing.allocator());
        if (!failing.has_induced_failure) {
            first_success = fail_index;
            try expectFindingNavigationTarget(&harness, layout, projection.mapped_entry_indices[projection.mapped_entry_indices.len - 1]);
            break;
        }

        try std.testing.expectEqualStrings("Could not prepare Finding navigation", harness.page_state.status.text());
        try std.testing.expectEqualDeep(viewer_before, harness.page_state.viewer);
        try std.testing.expectEqualDeep(card_before, harness.page_state.finding_card);
        try std.testing.expectEqualDeep(selection_before, harness.page_state.selection_owner);
        try std.testing.expectEqualDeep(search_before, harness.page_state.search);
        try std.testing.expect(std.meta.eql(cache_before, harness.loaded().rendered_line_cache));
        try std.testing.expectEqual(folds_before[0], harness.loaded().collapsed_hunks[0]);
        try std.testing.expectEqual(folds_before[1], harness.loaded().collapsed_hunks[1]);
        try std.testing.expectEqual(folds_before[2], harness.loaded().collapsed_hunks[2]);
        try std.testing.expectEqual(revision_before, harness.page_state.selection_layout_revision);
    }
    try std.testing.expect(first_success != null);
    try std.testing.expect(first_success.? >= review_navigation.FindingCardFramePreparation.allocation_count);
}

fn expectFindingNavigationTarget(
    harness: *FindingNavigationHarness,
    layout: diff_surface.Layout,
    entry_index: usize,
) !void {
    const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
    const model = finding_card.FindingCardModel.init(projection, entry_index).?;
    try std.testing.expect(harness.page_state.finding_card.matches(model));
    switch (harness.page_state.finding_card.focused.view) {
        .collapsed => {},
        .expanded => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualDeep(
        @as(?context.SelectedTarget, .{ .diff_file = model.span.file_ordinal }),
        harness.page_state.viewer.selected_target,
    );
    try std.testing.expectEqual(diff_surface.Focus.diff, harness.page_state.viewer.focus);
    try std.testing.expectEqualDeep(diff_view_model.BodyCoordinate{ .hunk_line = .{
        .hunk_index = model.span.hunk_ordinal,
        .line_index = model.span.last_diff_line_ordinal,
    } }, harness.page_state.viewer.diff_cursor);
    var frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(std.testing.allocator)).?;
    defer frame.deinit(std.testing.allocator);
    const card_index = frame.row_plan.cardIndex(model).?;
    const card_start = frame.presentation_rows.cardStart(card_index).?;
    const visible_rows = harness.controller(layout).navigationView().view().diffVisibleRows();
    try std.testing.expect(card_start >= harness.page_state.viewer.diff_scroll);
    if (visible_rows > 0) try std.testing.expect(card_start < harness.page_state.viewer.diff_scroll + visible_rows);
}

fn findingNavigationTreeNode(
    loaded: *const loaded_diff.LoadedDiff,
    kind: file_tree.Node.Kind,
    path: []const u8,
) ?usize {
    for (loaded.tree.nodes, 0..) |node, index| {
        if (node.kind == kind and std.mem.eql(u8, node.path, path)) return index;
    }
    return null;
}

fn resetFindingNavigationSource(harness: *FindingNavigationHarness, alpha_file: usize) void {
    harness.page_state.viewer.selected_target = .{ .diff_file = 0 };
    harness.page_state.viewer.selected_node = alpha_file;
    harness.page_state.finding_card = .unfocused;
}

const finding_navigation_patch =
    "diff --git a/src/alpha/a.zig b/src/alpha/a.zig\n" ++
    "index 1111111..2222222 100644\n" ++
    "--- a/src/alpha/a.zig\n" ++
    "+++ b/src/alpha/a.zig\n" ++
    "@@ -1,3 +1,3 @@ alpha first\n" ++
    " context-one\n" ++
    "-old-two\n" ++
    "+new-two\n" ++
    " context-three\n" ++
    "@@ -20,2 +20,2 @@ alpha second\n" ++
    " late-context\n" ++
    "-late-old\n" ++
    "+late-new\n" ++
    "diff --git a/src/beta/b.zig b/src/beta/b.zig\n" ++
    "new file mode 100644\n" ++
    "--- /dev/null\n" ++
    "+++ b/src/beta/b.zig\n" ++
    "@@ -0,0 +1,2 @@ beta\n" ++
    "+beta-context\n" ++
    "+beta-new\n";

const finding_navigation_rename_patch =
    "diff --git a/src/old_name.zig b/src/new_name.zig\n" ++
    "similarity index 80%\n" ++
    "rename from src/old_name.zig\n" ++
    "rename to src/new_name.zig\n" ++
    "index 1111111..2222222 100644\n" ++
    "--- a/src/old_name.zig\n" ++
    "+++ b/src/new_name.zig\n" ++
    "@@ -1,3 +1,3 @@ first\n" ++
    " context-one\n" ++
    "-old-two\n" ++
    "+new-two\n" ++
    " context-three\n" ++
    "@@ -20,2 +20,2 @@ second\n" ++
    " late-context\n" ++
    "-late-old\n" ++
    "+late-new\n" ++
    "diff --git a/src/beta/b.zig b/src/beta/b.zig\n" ++
    "new file mode 100644\n" ++
    "--- /dev/null\n" ++
    "+++ b/src/beta/b.zig\n" ++
    "@@ -0,0 +1,2 @@ beta\n" ++
    "+beta-context\n" ++
    "+beta-new\n";

const FindingNavigationHarness = struct {
    page_state: review_page.ReviewPageState,
    repository: repo_session.State = .{},
    store: ?review_store.ConfiguredStore = null,
    sessions: human_review_session.Owner = .{},

    fn init(allocator: std.mem.Allocator, rooted: bool) !FindingNavigationHarness {
        return initWithRename(allocator, rooted, false);
    }

    fn initRename(allocator: std.mem.Allocator) !FindingNavigationHarness {
        return initWithRename(allocator, true, true);
    }

    fn initWithRename(allocator: std.mem.Allocator, rooted: bool, rename: bool) !FindingNavigationHarness {
        const repository_id = try committed_review.ReviewRepositoryId.parse("e23e4567-e89b-42d3-a456-426614174000");
        const review_id = try committed_review.ReviewId.parse("f23e4567-e89b-42d3-a456-426614174000");
        const target: committed_review.CommittedReviewTarget = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = reviewAppTestOid('a'),
            .head_oid = reviewAppTestOid('b'),
            .diff_base_oid = reviewAppTestOid('a'),
        };
        const snapshot: review_store.StoreSnapshot = .{
            .root_device = 1,
            .root_inode = 2,
            .repository_locator = .{ .device = 3, .inode = 4 },
            .review_repository_id = repository_id,
        };
        var bundle = try findingNavigationPinnedBundle(allocator, snapshot, repository_id, review_id, target, rename);
        errdefer bundle.deinit(allocator);
        var loaded_bundle = try app_load.buildLoadedBundle(
            allocator,
            if (rename) finding_navigation_rename_patch else finding_navigation_patch,
        );
        errdefer loaded_bundle.deinit();
        const arena_allocator = loaded_bundle.arena.?.allocator();
        const reviewed_files = try arena_allocator.alloc(bool, loaded_bundle.loaded.document.files.len);
        @memset(reviewed_files, false);
        loaded_bundle.loaded.reviewed_files = reviewed_files;
        if (rooted) {
            const old_nodes = loaded_bundle.loaded.tree.nodes;
            const nodes = try arena_allocator.alloc(file_tree.Node, old_nodes.len + 1);
            nodes[0] = .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root };
            for (old_nodes, 0..) |old_node, index| {
                nodes[index + 1] = old_node;
                nodes[index + 1].depth += 1;
            }
            loaded_bundle.loaded.tree = .{ .nodes = nodes };
            try loaded_bundle.loaded.rebuildVisibleNodes(arena_allocator, false, .all);
        }
        const selected_node = loaded_bundle.loaded.tree.selectedNodeIndex(0).?;
        const base_display = try allocator.dupe(u8, "base");
        errdefer allocator.free(base_display);
        const head_display = try allocator.dupe(u8, "head");
        errdefer allocator.free(head_display);
        const loaded_value = loaded_bundle.loaded;
        const arena = loaded_bundle.takeArena();
        const selection = bundle.selection;
        bundle.selection = undefined;
        var finding_presentation_cache = try review_page.FindingPresentationCache.init(
            allocator,
            &selection,
            loaded_value.lines,
        );
        errdefer if (finding_presentation_cache) |*cache| cache.deinit(allocator);
        const result: FindingNavigationHarness = .{ .page_state = .{
            .load = .{ .state = .{ .loaded = .{ .arena = arena, .loaded = loaded_value } } },
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = selected_node,
                .focus = .sidebar,
                .display_mode = .unified,
            },
            .presentation = .{ .pinned_ai = .{
                .selection = selection,
                .base_display = base_display,
                .head_display = head_display,
                .finding_presentation_cache = finding_presentation_cache,
            } },
        } };
        finding_presentation_cache = null;
        return result;
    }

    fn deinit(self: *FindingNavigationHarness, allocator: std.mem.Allocator) void {
        if (self.store) |*value| value.deinit(allocator);
        self.repository.deinit(allocator);
        self.page_state.deinit(allocator);
        self.sessions.deinit();
        self.* = undefined;
    }

    fn controller(self: *FindingNavigationHarness, layout: diff_surface.Layout) review_coordinator.Controller {
        return .{
            .page_state = &self.page_state,
            .repo = self.repository.view(),
            .layout = layout,
            .env_map = null,
            .store = if (self.store) |*value| value else null,
            .sessions = &self.sessions,
        };
    }

    fn loaded(self: *FindingNavigationHarness) *loaded_diff.LoadedDiff {
        return switch (self.page_state.load.state) {
            .loaded => |*session| &session.loaded,
            else => unreachable,
        };
    }

    fn navigate(
        self: *FindingNavigationHarness,
        allocator: std.mem.Allocator,
        layout: diff_surface.Layout,
        scope: review_input.FindingNavigationIntent.Scope,
        direction: review_input.FindingNavigationIntent.Direction,
    ) !void {
        var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };
        var outcome = try self.controller(layout).update(&ctx, .{ .finding_navigation = .{
            .scope = scope,
            .direction = direction,
        } });
        outcome.deinit(allocator);
    }

    fn pointer(
        self: *FindingNavigationHarness,
        allocator: std.mem.Allocator,
        layout: diff_surface.Layout,
        point: diff_surface.MousePoint,
        button: review_input.FindingPointerEvent.Button,
    ) !review_coordinator.UpdateOutcome {
        var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };
        return self.controller(layout).update(&ctx, .{ .finding_pointer = .{
            .point = point,
            .button = button,
        } });
    }
};

test "Finding presentation cache reuses its exact frame and only prepares a visible body" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 80, .height = 10 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    harness.page_state.viewer.sidebar_hidden = true;
    harness.page_state.viewer.focus = .diff;
    const controller = harness.controller(layout);

    controller.ensureFindingPresentationCache();
    var frame = controller.navigationView().cachedFindingCardFrame() orelse return error.ExpectedFindingFrame;
    const model = frame.row_plan.cards[0];
    const initial_blocks_ptr = frame.presentation_rows.blocks.ptr;
    _ = harness.page_state.finding_card.apply(.{ .focus = model });
    _ = harness.page_state.finding_card.apply(.toggle);
    harness.page_state.advanceSelectionLayoutRevision();
    controller.ensureFindingPresentationCache();

    frame = controller.navigationView().cachedFindingCardFrame() orelse return error.ExpectedFindingFrame;
    const card_index = frame.row_plan.cardIndex(model) orelse return error.ExpectedFindingCard;
    const card_start = frame.presentation_rows.cardStart(card_index) orelse return error.ExpectedFindingCard;
    const content_width = review_page.findingCardContentWidth(controller.navigationView().findingCardRowWidth(model));
    const cache = &harness.page_state.pinnedAi().?.finding_presentation_cache.?;

    cache.invalidateBody();
    harness.page_state.viewer.diff_scroll = frame.presentation_rows.total_rows -| 1;
    controller.ensureFindingPresentationCache();
    try std.testing.expect(harness.page_state.cachedFindingBody(model, content_width) == null);

    harness.page_state.viewer.diff_scroll = card_start;
    controller.ensureFindingPresentationCache();
    const body = harness.page_state.cachedFindingBody(model, content_width) orelse return error.ExpectedFindingBody;
    try std.testing.expect(body.rowCount() > 0);
    const body_ptr = body.text.ptr;
    const retained_blocks_ptr = frame.presentation_rows.blocks.ptr;
    try std.testing.expectEqual(initial_blocks_ptr, retained_blocks_ptr);
    controller.ensureFindingPresentationCache();
    const steady = harness.page_state.cachedFindingBody(model, content_width) orelse return error.ExpectedFindingBody;
    try std.testing.expectEqual(body_ptr, steady.text.ptr);
    try std.testing.expectEqual(retained_blocks_ptr, controller.navigationView().cachedFindingCardFrame().?.presentation_rows.blocks.ptr);

    harness.page_state.releaseFindingPresentationCache(allocator);
    try std.testing.expect(harness.page_state.pinnedAi().?.finding_presentation_cache == null);
    controller.ensureFindingPresentationCache();
    try std.testing.expect(controller.navigationView().cachedFindingCardFrame() == null);
}

test "Finding cache lifecycle cannot re-admit a released retained presentation" {
    const allocator = std.testing.allocator;
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    const controller = harness.controller(.{ .width = 80, .height = 24 });
    controller.ensureFindingPresentationCache();
    try std.testing.expect(controller.navigationView().cachedFindingCardFrame() != null);

    harness.page_state.releaseFindingPresentationCache(allocator);
    controller.ensureFindingPresentationCache();
    try std.testing.expect(harness.page_state.pinnedAi().?.finding_presentation_cache == null);
    try std.testing.expect(controller.navigationView().cachedFindingCardFrame() == null);
}

test "Finding cache lifecycle admission failure preserves the previous selected owner" {
    const allocator = std.testing.allocator;
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    const current = harness.page_state.pinnedAiConst().?;
    const old_review_id = current.reviewId();
    const old_capacity = current.finding_presentation_cache.?.logicalCapacityBytes();
    const incoming_review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174099");
    var incoming = try findingNavigationPinnedBundle(
        allocator,
        current.selection.snapshot,
        current.selection.artifacts.manifest.value.review_repository_id,
        incoming_review_id,
        current.target(),
        false,
    );
    defer incoming.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        harness.page_state.commitPinnedAi(failing.allocator(), 0, null, null, &incoming),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(harness.page_state.activeAiReviewId().?.eql(old_review_id));
    try std.testing.expectEqual(
        old_capacity,
        harness.page_state.pinnedAiConst().?.finding_presentation_cache.?.logicalCapacityBytes(),
    );
}

test "Finding card admission rejects a copied mismatched side" {
    const allocator = std.testing.allocator;
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);

    const selection = &harness.page_state.pinnedAiConst().?.selection;
    const indices = selection.finding_projection.files[0].mapped_entry_indices;
    try std.testing.expect(indices.len >= 3);
    for (indices[0..3]) |entry_index| {
        const admitted = finding_card.FindingCardModel.init(&selection.finding_projection, entry_index).?;
        try std.testing.expect(review_page.findingCardContent(selection, admitted) != null);
        var mismatched = admitted;
        mismatched.side = switch (admitted.side) {
            .before => .after,
            .after => .before,
        };
        try std.testing.expect(review_page.findingCardContent(selection, mismatched) == null);
    }
}

test "side-by-side Finding cards bind rename paths and declared sides" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 120, .height = 16 };
    var harness = try FindingNavigationHarness.initRename(allocator);
    defer harness.deinit(allocator);
    harness.page_state.viewer.sidebar_hidden = true;
    harness.page_state.viewer.focus = .diff;
    harness.page_state.viewer.display_mode = .side_by_side;

    const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
    const indices = projection.files[0].mapped_entry_indices;
    const context_model = finding_card.FindingCardModel.init(projection, indices[0]).?;
    const removed_model = finding_card.FindingCardModel.init(projection, indices[1]).?;
    const added_model = finding_card.FindingCardModel.init(projection, indices[2]).?;
    try std.testing.expectEqual(committed_review.AnchorSide.after, context_model.side);
    try std.testing.expectEqual(committed_review.AnchorSide.before, removed_model.side);
    try std.testing.expectEqual(committed_review.AnchorSide.after, added_model.side);
    const findings = harness.page_state.pinnedAiConst().?.selection.artifacts.findings.value.findings;
    try std.testing.expectEqualStrings("src/old_name.zig", findings[indices[1]].anchor.path_bytes);
    try std.testing.expectEqualStrings("src/new_name.zig", findings[indices[2]].anchor.path_bytes);

    const navigation_view = harness.controller(layout).navigationView();
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, navigation_view.view().effectiveDisplayMode());
    var frame = (try navigation_view.buildFindingCardFrame(allocator)).?;
    defer frame.deinit(allocator);
    const context_index = frame.row_plan.cardIndex(context_model).?;
    const removed_index = frame.row_plan.cardIndex(removed_model).?;
    const added_index = frame.row_plan.cardIndex(added_model).?;
    const context_block = findingPointerBlock(frame.presentation_rows, .card, context_index).?;
    const removed_block = findingPointerBlock(frame.presentation_rows, .card, removed_index).?;
    const added_block = findingPointerBlock(frame.presentation_rows, .card, added_index).?;
    try std.testing.expectEqual(diff_render.InlineBlockPlacement.new, context_block.placement);
    try std.testing.expectEqual(diff_render.InlineBlockPlacement.old, removed_block.placement);
    try std.testing.expectEqual(diff_render.InlineBlockPlacement.new, added_block.placement);
    try std.testing.expectEqual(removed_block.after_source_offset, added_block.after_source_offset);
    try std.testing.expectEqual(removed_block.presentation_start, added_block.presentation_start);

    var paired_spacers: usize = 0;
    for (frame.presentation_rows.blocks) |block| {
        if (block.after_source_offset != removed_block.after_source_offset) continue;
        switch (block.kind) {
            .spacer => paired_spacers += 1,
            .card => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), paired_spacers);

    const file = harness.loaded().document.files[0];
    const hunk = file.hunks[removed_model.span.hunk_ordinal];
    try std.testing.expect(diff_view_model.sideBySideRenderedOffsetForLineOnSide(
        hunk.lines,
        removed_model.span.last_diff_line_ordinal,
        .old,
    ) != null);
    try std.testing.expect(diff_view_model.sideBySideRenderedOffsetForLineOnSide(
        hunk.lines,
        removed_model.span.last_diff_line_ordinal,
        .new,
    ) == null);
    try std.testing.expect(diff_view_model.sideBySideRenderedOffsetForLineOnSide(
        hunk.lines,
        added_model.span.last_diff_line_ordinal,
        .new,
    ) != null);
    try std.testing.expect(diff_view_model.sideBySideRenderedOffsetForLineOnSide(
        hunk.lines,
        added_model.span.last_diff_line_ordinal,
        .old,
    ) == null);

    var expanded_state: finding_card.State = .unfocused;
    _ = expanded_state.apply(.{ .focus = removed_model });
    _ = expanded_state.apply(.toggle);
    var expanded = (try navigation_view.buildFindingCardFrameForState(allocator, expanded_state)).?;
    defer expanded.deinit(allocator);
    const expanded_old = findingPointerBlock(expanded.presentation_rows, .card, expanded.row_plan.cardIndex(removed_model).?).?;
    const collapsed_new = findingPointerBlock(expanded.presentation_rows, .card, expanded.row_plan.cardIndex(added_model).?).?;
    const geometry = diff_render.sideBySideGeometry(diff_render.bodyWidth(navigation_view.view().diffPaneWidth()));
    const padding_row = expanded_old.presentation_start + 2;
    try std.testing.expectEqualDeep(
        diff_render.PresentationCellHit{ .card = .{
            .token = expanded.row_plan.cardIndex(removed_model).?,
            .local_row = 2,
            .local_col = 2,
        } },
        expanded.presentation_rows.hitAtCell(
            padding_row,
            diff_render.cursor_gutter_width + geometry.old.col + 2,
            .side_by_side,
            geometry,
        ).?,
    );
    try std.testing.expect(padding_row >= collapsed_new.presentation_start + collapsed_new.height);
    try std.testing.expectEqual(
        diff_render.PresentationCellHit.padding,
        expanded.presentation_rows.hitAtCell(
            padding_row,
            diff_render.cursor_gutter_width + geometry.new.col + 2,
            .side_by_side,
            geometry,
        ).?,
    );

    harness.page_state.finding_card = .unfocused;
    harness.page_state.viewer.diff_cursor = .{ .hunk_line = .{
        .hunk_index = removed_model.span.hunk_ordinal,
        .line_index = removed_model.span.last_diff_line_ordinal,
    } };
    try std.testing.expect(navigation_view.findingCardAtCursor());
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };
    var first_cycle = try harness.controller(layout).update(&ctx, .{ .finding_card = .focus_or_cycle });
    first_cycle.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.matches(removed_model));
    var second_cycle = try harness.controller(layout).update(&ctx, .{ .finding_card = .focus_or_cycle });
    second_cycle.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.matches(added_model));

    const narrow_view = harness.controller(.{ .width = 40, .height = 16 }).navigationView();
    try std.testing.expectEqual(diff_render.DisplayMode.unified, narrow_view.view().effectiveDisplayMode());
    var narrow_frame = (try narrow_view.buildFindingCardFrame(allocator)).?;
    defer narrow_frame.deinit(allocator);
    for (narrow_frame.presentation_rows.blocks) |block| {
        try std.testing.expectEqual(diff_render.InlineBlockPlacement.full, block.placement);
    }
    try std.testing.expect(harness.page_state.finding_card.matches(added_model));
}

test "Finding disposition controller edits once, retries draft saves, and directly reloads drift" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 20 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    const selection = &harness.page_state.pinnedAiConst().?.selection;
    const manifest = &selection.artifacts.manifest.value;
    const binding: review_store.ReviewRunBinding = .{
        .review_repository_id = manifest.review_repository_id,
        .review_id = manifest.review_id,
        .target = manifest.target,
        .findings_digest = manifest.findings_digest,
    };
    harness.sessions.current = try human_review_session.Session.init(
        allocator,
        binding,
        &selection.artifacts.findings.value,
        null,
        null,
    );
    const projection = &selection.finding_projection;
    const finding_count = selection.artifacts.findings.value.findings.len;
    const model = finding_card.FindingCardModel.init(projection, projection.files[0].mapped_entry_indices[0]).?;
    _ = harness.page_state.finding_card.apply(.{ .focus = model });
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    var accepted = try harness.controller(layout).update(&ctx, .{ .finding_card = .accept });
    defer accepted.deinit(allocator);
    try std.testing.expect(accepted.takeHumanReviewSave());
    const session = harness.sessions.currentSession().?;
    try std.testing.expectEqual(
        committed_review.FindingDispositionValue.accepted,
        session.workingSnapshot().?.finding_dispositions[0].disposition,
    );
    const accepted_generation = session.generation;
    var unchanged = try harness.controller(layout).update(&ctx, .{ .finding_card = .accept });
    defer unchanged.deinit(allocator);
    try std.testing.expect(!unchanged.takeHumanReviewSave());
    try std.testing.expectEqual(accepted_generation, session.generation);

    inline for (.{
        .{ review_input.FindingCardMsg.dismiss, committed_review.FindingDispositionValue.dismissed },
        .{ review_input.FindingCardMsg.unreview, committed_review.FindingDispositionValue.unreviewed },
        .{ review_input.FindingCardMsg.accept, committed_review.FindingDispositionValue.accepted },
    }) |case| {
        var changed = try harness.controller(layout).update(&ctx, .{ .finding_card = case[0] });
        defer changed.deinit(allocator);
        try std.testing.expect(changed.takeHumanReviewSave());
        try std.testing.expectEqual(case[1], session.workingSnapshot().?.finding_dispositions[0].disposition);
    }

    var app: app_root.App = .{
        .active_page = .review,
        .allocator = allocator,
        .terminal_size = .{ .width = layout.width, .height = layout.height },
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
    };
    harness.store = null;
    app.pages.review = harness.page_state;
    harness.page_state = .{};
    app.human_review_sessions = harness.sessions;
    harness.sessions = .{};
    var app_owns_harness_state = true;
    defer {
        app.review_store_operations.deinit(allocator);
        if (app_owns_harness_state) {
            harness.sessions = app.human_review_sessions;
            app.human_review_sessions = .{};
            harness.page_state = app.pages.review;
            app.pages.review = .{};
            harness.store = app.configured_review_store;
            app.configured_review_store = null;
        }
    }

    try std.testing.expect(app.review_store_operations.requestQuit() == .ready);
    const rejected = try app.saveHumanReviewSession(&ctx);
    try std.testing.expectEqual(
        app_root.HumanReviewSaveOutcome{ .rejected = .admission_closed },
        rejected,
    );
    const admission_session = app.human_review_sessions.currentSession().?;
    try std.testing.expectEqual(@as(usize, 0), admission_session.operationCount());
    try std.testing.expectEqual(human_review_session.Lifecycle.failed, admission_session.lifecycle());
    app.review_store_operations.reopenAfterReconciliation();

    try app.update(.{ .review = .{ .finding_card = .retry } }, &ctx);
    try std.testing.expectEqual(@as(usize, 1), admission_session.operationCount());
    try std.testing.expectEqual(human_review_session.Lifecycle.saving, admission_session.lifecycle());
    try std.testing.expectEqual(
        committed_review.FindingDispositionValue.accepted,
        admission_session.workingSnapshot().?.finding_dispositions[0].disposition,
    );
    try std.testing.expectEqual(
        finding_count,
        admission_session.workingSnapshot().?.finding_dispositions.len,
    );
    for (admission_session.workingSnapshot().?.finding_dispositions[1..]) |disposition| {
        try std.testing.expectEqual(committed_review.FindingDispositionValue.unreviewed, disposition.disposition);
    }
    try app.update(.{ .review = .{ .finding_card = .retry } }, &ctx);
    var admission_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), admission_tasks.len);
    const admission_failure = admission_tasks[0].failed(admission_tasks[0].ctx, .runtime_abandoned, allocator);
    const admission_operation_id = admission_failure.review_store_operation_finished.operation_id;
    try app.update(admission_failure, &ctx);
    try std.testing.expectEqual(human_review_session.Lifecycle.failed, admission_session.lifecycle());

    try app.update(.{ .review = .{ .finding_card = .retry } }, &ctx);
    var persistence_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), persistence_tasks.len);
    const persistence_failure = persistence_tasks[0].failed(persistence_tasks[0].ctx, .runtime_abandoned, allocator);
    try std.testing.expect(persistence_failure.review_store_operation_finished.operation_id != admission_operation_id);
    try app.update(persistence_failure, &ctx);
    try std.testing.expectEqual(human_review_session.Lifecycle.failed, admission_session.lifecycle());

    harness.sessions = app.human_review_sessions;
    app.human_review_sessions = .{};
    harness.page_state = app.pages.review;
    app.pages.review = .{};
    harness.store = app.configured_review_store;
    app.configured_review_store = null;
    app_owns_harness_state = false;
    const recovered_session = harness.sessions.currentSession().?;

    const drift_preparation = try recovered_session.prepareSave(
        allocator,
        .{ .binding = binding, .epoch = 2 },
        .dirty_only,
    );
    var drift = drift_preparation.ready;
    defer drift.deinit();
    recovered_session.commitDraft(&drift, 702, null);
    try std.testing.expectEqual(
        human_review_session.Reduction.reconciliation_required,
        recovered_session.reduce(.{
            .operation_id = 702,
            .binding = binding,
            .kind = .draft,
            .expected_revision = 0,
            .committed_revision = null,
            .completed_at = null,
            .failure = .conflict,
        }),
    );

    var roots = try TestRepoPair.init();
    defer roots.deinit();
    harness.repository.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
    harness.repository.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = harness.page_state.activate(harness.repository.repo_epoch);
    var reload = try harness.controller(layout).update(&ctx, .{ .finding_card = .retry });
    defer reload.deinit(allocator);
    try std.testing.expect(!reload.takeHumanReviewSave());
    try std.testing.expect(harness.page_state.ai_reviews.phase == .selection_loading);
    try std.testing.expect(harness.page_state.ai_reviews.phase.selection_loading.direct);
    const tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    var abandoned = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

fn findingPointerPoint(
    harness: *FindingNavigationHarness,
    layout: diff_surface.Layout,
    presentation_offset: usize,
    local_col: u16,
) !diff_surface.MousePoint {
    const view = harness.controller(layout).navigationView().view();
    const raw = view.rawDiffPaneGeometry() orelse return error.ExpectedDiffPane;
    const scroll = harness.page_state.viewer.diff_scroll;
    if (presentation_offset < scroll) return error.ExpectedVisiblePresentationRow;
    const visible_row = presentation_offset - scroll;
    if (visible_row >= view.diffVisibleRows()) return error.ExpectedVisiblePresentationRow;
    return .{
        .col = raw.col + (raw.width - view.diffPaneWidth()) + local_col,
        .row = diff_render.body_start_row + @as(u16, @intCast(visible_row)),
    };
}

fn findingPointerBlock(
    rows: diff_render.PresentationRows,
    kind: enum { card, spacer },
    token: usize,
) ?diff_render.InlineBlock {
    for (rows.blocks) |block| switch (block.kind) {
        .card => |candidate| if (kind == .card and candidate == token) return block,
        .spacer => if (kind == .spacer) return block,
    };
    return null;
}

test "side-by-side Finding pointer keeps pane-local actions and inert padding" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 120, .height = 18 };
    var harness = try FindingNavigationHarness.initRename(allocator);
    defer harness.deinit(allocator);
    harness.page_state.viewer.sidebar_hidden = true;
    harness.page_state.viewer.focus = .diff;
    harness.page_state.viewer.display_mode = .side_by_side;

    const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
    const model = finding_card.FindingCardModel.init(projection, projection.files[0].mapped_entry_indices[0]).?;
    const navigation_view = harness.controller(layout).navigationView();
    const geometry = diff_render.sideBySideGeometry(diff_render.bodyWidth(navigation_view.view().diffPaneWidth()));
    var collapsed = (try navigation_view.buildFindingCardFrame(allocator)).?;
    const card_index = collapsed.row_plan.cardIndex(model).?;
    const card_start = collapsed.presentation_rows.cardStart(card_index).?;
    harness.page_state.viewer.diff_scroll = @min(
        card_start,
        collapsed.presentation_rows.total_rows -| navigation_view.view().diffVisibleRows(),
    );
    const header = try findingPointerPoint(
        &harness,
        layout,
        card_start,
        diff_render.cursor_gutter_width + geometry.new.col + 5,
    );
    collapsed.deinit(allocator);

    var focus = try harness.pointer(allocator, layout, header, .left);
    focus.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.matches(model));
    var focused = (try navigation_view.buildFindingCardFrame(allocator)).?;
    const focused_header = try findingPointerPoint(
        &harness,
        layout,
        focused.presentation_rows.cardStart(card_index).?,
        diff_render.cursor_gutter_width + geometry.new.col + 5,
    );
    focused.deinit(allocator);
    var expand = try harness.pointer(allocator, layout, focused_header, .left);
    expand.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.expanded(model));

    var expanded = (try navigation_view.buildFindingCardFrame(allocator)).?;
    defer expanded.deinit(allocator);
    const expanded_start = expanded.presentation_rows.cardStart(card_index).?;
    const right_body = try findingPointerPoint(
        &harness,
        layout,
        expanded_start + 1,
        diff_render.cursor_gutter_width + geometry.new.col + 8,
    );
    const max_body_scroll = try review_page.findingCardMaxBodyScroll(
        allocator,
        harness.page_state.contentForFindingCard(model).?,
        review_page.findingCardContentWidth(navigation_view.findingCardRowWidth(model)),
    );
    try std.testing.expect(max_body_scroll > 0);
    const viewport_before_body_scroll = harness.page_state.viewer.diff_scroll;
    var body_wheel = try harness.pointer(allocator, layout, right_body, .wheel_down);
    body_wheel.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), harness.page_state.finding_card.bodyScroll(model));
    try std.testing.expectEqual(viewport_before_body_scroll, harness.page_state.viewer.diff_scroll);

    const left_padding = try findingPointerPoint(
        &harness,
        layout,
        expanded_start + 1,
        diff_render.cursor_gutter_width + geometry.old.col + 5,
    );
    var expanded_view = navigation_view.withPresentationRows(&expanded.presentation_rows);
    var resolver = expanded_view.resolver();
    try std.testing.expectEqualDeep(
        diff_surface.navigation.PresentationCellHit{ .spacer = .{
            .local_col = diff_render.cursor_gutter_width + geometry.old.col + 5,
        } },
        expanded_view.bodyView(&resolver).presentationCellHit(left_padding).?,
    );
    const card_before_padding = harness.page_state.finding_card;
    const viewer_before_padding = harness.page_state.viewer;
    var padding_click = try harness.pointer(allocator, layout, left_padding, .left);
    padding_click.deinit(allocator);
    var padding_horizontal = try harness.pointer(allocator, layout, left_padding, .wheel_right);
    padding_horizontal.deinit(allocator);
    try std.testing.expectEqualDeep(card_before_padding, harness.page_state.finding_card);
    try std.testing.expectEqualDeep(viewer_before_padding, harness.page_state.viewer);
    try std.testing.expect(harness.page_state.selection_owner == .none);

    const separator = try findingPointerPoint(
        &harness,
        layout,
        expanded_start + 1,
        diff_render.cursor_gutter_width + geometry.separator_col,
    );
    var separator_click = try harness.pointer(allocator, layout, separator, .left);
    separator_click.deinit(allocator);
    try std.testing.expectEqualDeep(card_before_padding, harness.page_state.finding_card);
    try std.testing.expectEqualDeep(viewer_before_padding, harness.page_state.viewer);

    const footer_target = finding_card_view.footerCopyTarget(navigation_view.findingCardRowWidth(model)).?;
    const footer = try findingPointerPoint(
        &harness,
        layout,
        expanded_start + finding_card.footer_row,
        diff_render.cursor_gutter_width + geometry.new.col + footer_target.start,
    );
    var copy = try harness.pointer(allocator, layout, footer, .left);
    defer copy.deinit(allocator);
    try std.testing.expectEqualStrings("Finding", copy.clipboard.?.label);

    const viewport_max = expanded.presentation_rows.total_rows -| navigation_view.view().diffVisibleRows();
    const padding_button: review_input.FindingPointerEvent.Button = if (viewer_before_padding.diff_scroll < viewport_max)
        .wheel_down
    else
        .wheel_up;
    const expected_viewport = if (padding_button == .wheel_down)
        @min(viewer_before_padding.diff_scroll + 1, viewport_max)
    else
        viewer_before_padding.diff_scroll -| 1;
    var padding_vertical = try harness.pointer(allocator, layout, left_padding, padding_button);
    padding_vertical.deinit(allocator);
    try std.testing.expectEqual(expected_viewport, harness.page_state.viewer.diff_scroll);
    try std.testing.expectEqualDeep(card_before_padding, harness.page_state.finding_card);
}

test "Finding pointer routes exact card cells with one semantic command" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 18 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    harness.page_state.viewer.sidebar_hidden = true;

    const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
    const model = finding_card.FindingCardModel.init(projection, projection.files[0].mapped_entry_indices[0]).?;
    var collapsed = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const card_index = collapsed.row_plan.cardIndex(model).?;
    const card_start = collapsed.presentation_rows.cardStart(card_index).?;
    harness.page_state.viewer.diff_scroll = @min(
        card_start,
        collapsed.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows(),
    );
    const header = try findingPointerPoint(&harness, layout, card_start, 5);
    var collapsed_view = harness.controller(layout).navigationView().withPresentationRows(&collapsed.presentation_rows);
    var collapsed_resolver = collapsed_view.resolver();
    try std.testing.expectEqualDeep(
        diff_surface.navigation.PresentationCellHit{ .card = .{
            .token = card_index,
            .local_row = 0,
            .local_col = 5,
        } },
        collapsed_view.bodyView(&collapsed_resolver).presentationCellHit(header).?,
    );
    collapsed.deinit(allocator);

    var focus = try harness.pointer(allocator, layout, header, .left);
    defer focus.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.matches(model));
    try std.testing.expect(!harness.page_state.finding_card.expanded(model));
    try std.testing.expectEqual(diff_surface.Focus.diff, harness.page_state.viewer.focus);
    try std.testing.expect(!harness.page_state.selection_owner.activeMouseSelection());

    var focused_frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const focused_start = focused_frame.presentation_rows.cardStart(card_index).?;
    const focused_header = try findingPointerPoint(&harness, layout, focused_start, 5);
    focused_frame.deinit(allocator);
    var expand = try harness.pointer(allocator, layout, focused_header, .left);
    defer expand.deinit(allocator);
    try std.testing.expect(harness.page_state.finding_card.expanded(model));

    var expanded = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const expanded_start = expanded.presentation_rows.cardStart(card_index).?;
    const body_point = try findingPointerPoint(&harness, layout, expanded_start + 1, 8);
    var expanded_view = harness.controller(layout).navigationView().withPresentationRows(&expanded.presentation_rows);
    var expanded_resolver = expanded_view.resolver();
    try std.testing.expectEqualDeep(
        diff_surface.navigation.PresentationCellHit{ .card = .{
            .token = card_index,
            .local_row = 1,
            .local_col = 8,
        } },
        expanded_view.bodyView(&expanded_resolver).presentationCellHit(body_point).?,
    );
    expanded.deinit(allocator);

    const viewport_before_body_scroll = harness.page_state.viewer.diff_scroll;
    const content = harness.page_state.contentForFindingCard(model).?;
    const max_body_scroll = try review_page.findingCardMaxBodyScroll(
        allocator,
        content,
        review_page.findingCardContentWidth(harness.controller(layout).navigationView().view().diffPaneWidth()),
    );
    try std.testing.expect(max_body_scroll > 0);
    for (0..max_body_scroll + 2) |_| {
        var wheel = try harness.pointer(allocator, layout, body_point, .wheel_down);
        wheel.deinit(allocator);
    }
    try std.testing.expectEqual(max_body_scroll, harness.page_state.finding_card.bodyScroll(model));
    try std.testing.expectEqual(viewport_before_body_scroll, harness.page_state.viewer.diff_scroll);
    const card_before_horizontal = harness.page_state.finding_card;
    var horizontal = try harness.pointer(allocator, layout, body_point, .wheel_right);
    horizontal.deinit(allocator);
    try std.testing.expectEqualDeep(card_before_horizontal, harness.page_state.finding_card);
    try std.testing.expectEqual(viewport_before_body_scroll, harness.page_state.viewer.diff_scroll);

    var footer_frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const footer_start = footer_frame.presentation_rows.cardStart(card_index).?;
    const footer_target = finding_card_view.footerCopyTarget(harness.controller(layout).navigationView().view().diffPaneWidth()).?;
    const footer_point = try findingPointerPoint(
        &harness,
        layout,
        footer_start + finding_card.footer_row,
        footer_target.start,
    );
    footer_frame.deinit(allocator);
    var copy = try harness.pointer(allocator, layout, footer_point, .left);
    defer copy.deinit(allocator);
    try std.testing.expectEqualStrings("Finding", copy.clipboard.?.label);
    try std.testing.expectEqualStrings(
        "alpha context\n\nfirst context line\nsecond context line\nthird context line\nfourth context line\nfifth context line\nsixth context line\nseventh context line",
        copy.clipboard.?.text,
    );
    const no_copy_point = try findingPointerPoint(
        &harness,
        layout,
        footer_start + finding_card.footer_row,
        footer_target.start - 1,
    );
    var no_copy = try harness.pointer(allocator, layout, no_copy_point, .left);
    defer no_copy.deinit(allocator);
    try std.testing.expect(no_copy.clipboard == null);

    const collapse_header = try findingPointerPoint(&harness, layout, footer_start, 5);
    var collapse = try harness.pointer(allocator, layout, collapse_header, .left);
    collapse.deinit(allocator);
    try std.testing.expect(!harness.page_state.finding_card.expanded(model));
    var collapsed_again = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const collapsed_again_start = collapsed_again.presentation_rows.cardStart(card_index).?;
    const collapsed_again_point = try findingPointerPoint(&harness, layout, collapsed_again_start, 5);
    const viewport_before_collapsed = harness.page_state.viewer.diff_scroll;
    const viewport_max = collapsed_again.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows();
    const collapsed_button: review_input.FindingPointerEvent.Button = if (viewport_before_collapsed < viewport_max) .wheel_down else .wheel_up;
    const expected_collapsed_scroll = if (collapsed_button == .wheel_down)
        @min(viewport_before_collapsed + 1, viewport_max)
    else
        viewport_before_collapsed -| 1;
    collapsed_again.deinit(allocator);
    var collapsed_wheel = try harness.pointer(allocator, layout, collapsed_again_point, collapsed_button);
    collapsed_wheel.deinit(allocator);
    try std.testing.expectEqual(expected_collapsed_scroll, harness.page_state.viewer.diff_scroll);
    try std.testing.expect(!harness.page_state.finding_card.expanded(model));

    var spacer_frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const spacer = findingPointerBlock(spacer_frame.presentation_rows, .spacer, 0).?;
    harness.page_state.viewer.diff_scroll = @min(
        spacer.presentation_start,
        spacer_frame.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows(),
    );
    const spacer_point = try findingPointerPoint(&harness, layout, spacer.presentation_start, 7);
    const spacer_scroll_before = harness.page_state.viewer.diff_scroll;
    const spacer_max = spacer_frame.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows();
    const spacer_button: review_input.FindingPointerEvent.Button = if (spacer_scroll_before < spacer_max) .wheel_down else .wheel_up;
    const expected_spacer_scroll = if (spacer_button == .wheel_down)
        @min(spacer_scroll_before + 1, spacer_max)
    else
        spacer_scroll_before -| 1;
    var spacer_view = harness.controller(layout).navigationView().withPresentationRows(&spacer_frame.presentation_rows);
    var spacer_resolver = spacer_view.resolver();
    try std.testing.expectEqualDeep(
        diff_surface.navigation.PresentationCellHit{ .spacer = .{ .local_col = 7 } },
        spacer_view.bodyView(&spacer_resolver).presentationCellHit(spacer_point).?,
    );
    spacer_frame.deinit(allocator);
    const spacer_viewer_before = harness.page_state.viewer;
    const spacer_card_before = harness.page_state.finding_card;
    var spacer_press = try harness.pointer(allocator, layout, spacer_point, .left);
    spacer_press.deinit(allocator);
    var spacer_horizontal = try harness.pointer(allocator, layout, spacer_point, .wheel_left);
    spacer_horizontal.deinit(allocator);
    try std.testing.expectEqualDeep(spacer_viewer_before, harness.page_state.viewer);
    try std.testing.expectEqualDeep(spacer_card_before, harness.page_state.finding_card);
    try std.testing.expect(harness.page_state.selection_owner == .none);

    var spacer_wheel = try harness.pointer(allocator, layout, spacer_point, spacer_button);
    spacer_wheel.deinit(allocator);
    try std.testing.expectEqual(expected_spacer_scroll, harness.page_state.viewer.diff_scroll);

    var shared_frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const shared_source_offset = shared_frame.presentation_rows.blocks[0].after_source_offset;
    const shared_source_presentation = shared_frame.presentation_rows.sourceToPresentation(shared_source_offset).?;
    const shared_max = shared_frame.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows();
    harness.page_state.viewer.diff_scroll = @min(
        shared_source_presentation,
        shared_max,
    );
    const shared_source_point = try findingPointerPoint(&harness, layout, shared_source_presentation, 12);
    var shared_view = harness.controller(layout).navigationView().withPresentationRows(&shared_frame.presentation_rows);
    var shared_resolver = shared_view.resolver();
    try std.testing.expectEqualDeep(
        diff_surface.navigation.PresentationCellHit{ .source = .{
            .source_offset = shared_source_offset,
            .local_col = 12,
        } },
        shared_view.bodyView(&shared_resolver).presentationCellHit(shared_source_point).?,
    );
    shared_frame.deinit(allocator);
    const source_scroll_before = harness.page_state.viewer.diff_scroll;
    const source_button: review_input.FindingPointerEvent.Button = if (source_scroll_before < shared_max) .wheel_down else .wheel_up;
    const expected_source_scroll = if (source_button == .wheel_down)
        @min(source_scroll_before + 1, shared_max)
    else
        source_scroll_before -| 1;
    var source_wheel = try harness.pointer(allocator, layout, shared_source_point, source_button);
    source_wheel.deinit(allocator);
    try std.testing.expectEqual(expected_source_scroll, harness.page_state.viewer.diff_scroll);

    harness.page_state.viewer.diff_scroll = @min(@as(usize, 1), shared_max);
    const header_scroll_before = harness.page_state.viewer.diff_scroll;
    const header_button: review_input.FindingPointerEvent.Button = if (header_scroll_before > 0) .wheel_up else .wheel_down;
    const expected_header_scroll = if (header_button == .wheel_down)
        @min(header_scroll_before + 1, shared_max)
    else
        header_scroll_before -| 1;
    const header_point: diff_surface.MousePoint = .{ .col = 12, .row = 0 };
    var header_wheel = try harness.pointer(allocator, layout, header_point, header_button);
    header_wheel.deinit(allocator);
    try std.testing.expectEqual(expected_header_scroll, harness.page_state.viewer.diff_scroll);
}

test "Finding pointer isolates card selection lifecycle and allocation failures" {
    const allocator = std.testing.allocator;
    const layout: diff_surface.Layout = .{ .width = 100, .height = 12 };
    var harness = try FindingNavigationHarness.init(allocator, true);
    defer harness.deinit(allocator);
    harness.page_state.viewer.sidebar_hidden = true;
    const projection = &harness.page_state.pinnedAiConst().?.selection.finding_projection;
    const model = finding_card.FindingCardModel.init(projection, projection.files[0].mapped_entry_indices[0]).?;
    _ = harness.page_state.finding_card.apply(.{ .focus = model });
    _ = harness.page_state.finding_card.apply(.toggle);

    var frame = (try harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
    const card_index = frame.row_plan.cardIndex(model).?;
    const card = findingPointerBlock(frame.presentation_rows, .card, card_index).?;
    harness.page_state.viewer.diff_scroll = @min(
        card.presentation_start,
        frame.presentation_rows.total_rows -| harness.controller(layout).navigationView().view().diffVisibleRows(),
    );
    const card_body = try findingPointerPoint(&harness, layout, card.presentation_start + 1, 12);
    var card_press = try harness.pointer(allocator, layout, card_body, .left);
    card_press.deinit(allocator);
    try std.testing.expect(harness.page_state.selection_owner == .none);
    try std.testing.expect(harness.page_state.finding_card.expanded(model));

    const source_presentation = frame.presentation_rows.sourceToPresentation(card.after_source_offset).?;
    harness.page_state.viewer.diff_scroll = source_presentation;
    const source_point = try findingPointerPoint(&harness, layout, source_presentation, 12);
    const crossing_card = try findingPointerPoint(&harness, layout, card.presentation_start, 12);
    frame.deinit(allocator);
    var source_press = try harness.pointer(allocator, layout, source_point, .left);
    source_press.deinit(allocator);
    try std.testing.expect(harness.page_state.selection_owner.activeMouseSelection());
    const selection_before_crossing = harness.page_state.selection_owner;
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };
    var drag = try harness.controller(layout).update(&ctx, .{ .shared = .{ .mouse_diff_drag = crossing_card } });
    drag.deinit(allocator);
    try std.testing.expectEqualDeep(selection_before_crossing, harness.page_state.selection_owner);
    try std.testing.expect(harness.page_state.finding_card.expanded(model));
    var release = try harness.controller(layout).update(&ctx, .{ .shared = .{ .mouse_diff_release = null } });
    release.deinit(allocator);
    try std.testing.expect(!harness.page_state.selection_owner.activeMouseSelection());
    try std.testing.expect(harness.page_state.finding_card.expanded(model));

    const owner_after_release = harness.page_state.selection_owner;
    var orphan_drag = try harness.controller(layout).update(&ctx, .{ .shared = .{ .mouse_diff_drag = crossing_card } });
    orphan_drag.deinit(allocator);
    try std.testing.expectEqualDeep(owner_after_release, harness.page_state.selection_owner);
    var orphan_release = try harness.controller(layout).update(&ctx, .{ .shared = .{ .mouse_diff_release = null } });
    orphan_release.deinit(allocator);
    try std.testing.expect(!harness.page_state.selection_owner.activeMouseSelection());

    var first_success: ?usize = null;
    for (0..32) |fail_index| {
        var failing_harness = try FindingNavigationHarness.init(allocator, true);
        defer failing_harness.deinit(allocator);
        failing_harness.page_state.viewer.sidebar_hidden = true;
        var success_frame = (try failing_harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
        const success_start = success_frame.presentation_rows.cardStart(0).?;
        failing_harness.page_state.viewer.diff_scroll = @min(
            success_start,
            success_frame.presentation_rows.total_rows -| failing_harness.controller(layout).navigationView().view().diffVisibleRows(),
        );
        const failure_point = try findingPointerPoint(&failing_harness, layout, success_start, 5);
        success_frame.deinit(allocator);
        const viewer_before = failing_harness.page_state.viewer;
        const card_before = failing_harness.page_state.finding_card;
        const owner_before = failing_harness.page_state.selection_owner;
        const revision_before = failing_harness.page_state.selection_layout_revision;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var failing_outcome = try failing_harness.pointer(failing.allocator(), layout, failure_point, .left);
        failing_outcome.deinit(failing.allocator());
        if (!failing.has_induced_failure) {
            first_success = fail_index;
            try std.testing.expect(failing_harness.page_state.finding_card.isFocused());
            break;
        }
        try std.testing.expectEqualStrings("Could not resolve Finding pointer", failing_harness.page_state.status.text());
        try std.testing.expectEqualDeep(viewer_before, failing_harness.page_state.viewer);
        try std.testing.expectEqualDeep(card_before, failing_harness.page_state.finding_card);
        try std.testing.expectEqualDeep(owner_before, failing_harness.page_state.selection_owner);
        try std.testing.expectEqual(revision_before, failing_harness.page_state.selection_layout_revision);
    }
    try std.testing.expect(first_success != null);

    var first_shared_success: ?usize = null;
    for (0..64) |fail_index| {
        var failing_harness = try FindingNavigationHarness.init(allocator, true);
        defer failing_harness.deinit(allocator);
        failing_harness.page_state.viewer.sidebar_hidden = true;
        var success_frame = (try failing_harness.controller(layout).navigationView().buildFindingCardFrame(allocator)).?;
        const source_offset = success_frame.presentation_rows.blocks[0].after_source_offset;
        const shared_source_presentation = success_frame.presentation_rows.sourceToPresentation(source_offset).?;
        failing_harness.page_state.viewer.diff_scroll = shared_source_presentation;
        const failure_point = try findingPointerPoint(&failing_harness, layout, shared_source_presentation, 12);
        success_frame.deinit(allocator);
        const viewer_before = failing_harness.page_state.viewer;
        const card_before = failing_harness.page_state.finding_card;
        const owner_before = failing_harness.page_state.selection_owner;
        const revision_before = failing_harness.page_state.selection_layout_revision;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var failing_outcome = try failing_harness.pointer(failing.allocator(), layout, failure_point, .left);
        failing_outcome.deinit(failing.allocator());
        if (!failing.has_induced_failure) {
            first_shared_success = fail_index;
            try std.testing.expect(failing_harness.page_state.selection_owner.activeMouseSelection());
            break;
        }
        try std.testing.expectEqualStrings("Could not resolve Finding pointer", failing_harness.page_state.status.text());
        try std.testing.expectEqualDeep(viewer_before, failing_harness.page_state.viewer);
        try std.testing.expectEqualDeep(card_before, failing_harness.page_state.finding_card);
        try std.testing.expectEqualDeep(owner_before, failing_harness.page_state.selection_owner);
        try std.testing.expectEqual(revision_before, failing_harness.page_state.selection_layout_revision);
    }
    try std.testing.expect(first_shared_success != null);
}

fn findingNavigationPinnedBundle(
    allocator: std.mem.Allocator,
    snapshot: review_store.StoreSnapshot,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    rename: bool,
) !app_load.PinnedReviewLoadedBundle {
    const before_path = if (rename) "src/old_name.zig" else "src/alpha/a.zig";
    const after_path = if (rename) "src/new_name.zig" else "src/alpha/a.zig";
    const producer: committed_review.Producer = .{ .name = "reviewer", .model = "gpt-test" };
    const finding_values = [_]committed_review.Finding{
        .{
            .finding_id = .{ .bytes = "alpha-context" },
            .anchor = .{ .path_bytes = after_path, .side = .after, .start_line = 1, .end_line = 1, .content_digest = committed_review.Sha256Digest.hash("context-one\n") },
            .severity = .info,
            .title = "alpha context",
            .body = "first context line\nsecond context line\nthird context line\nfourth context line\nfifth context line\nsixth context line\nseventh context line",
        },
        .{
            .finding_id = .{ .bytes = "alpha-removed" },
            .anchor = .{ .path_bytes = before_path, .side = .before, .start_line = 2, .end_line = 2, .content_digest = committed_review.Sha256Digest.hash("old-two\n") },
            .severity = .warning,
            .title = "alpha removed",
            .body = "removed line",
        },
        .{
            .finding_id = .{ .bytes = "alpha-added" },
            .anchor = .{ .path_bytes = after_path, .side = .after, .start_line = 2, .end_line = 2, .content_digest = committed_review.Sha256Digest.hash("new-two\n") },
            .severity = .@"error",
            .title = "alpha added",
            .body = "added line",
        },
        .{
            .finding_id = .{ .bytes = "alpha-late" },
            .anchor = .{ .path_bytes = after_path, .side = .after, .start_line = 21, .end_line = 21, .content_digest = committed_review.Sha256Digest.hash("late-new\n") },
            .severity = .warning,
            .title = "alpha late",
            .body = "second hunk",
        },
        .{
            .finding_id = .{ .bytes = "beta-added" },
            .anchor = .{ .path_bytes = "src/beta/b.zig", .side = .after, .start_line = 1, .end_line = 1, .content_digest = committed_review.Sha256Digest.hash("beta-context\n") },
            .severity = .info,
            .title = "beta added",
            .body = "added file",
        },
    };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-09-03T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &finding_values,
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
        .created_at = "2026-09-03T00:00:00Z",
        .display = .{ .base_label = "main", .head_label = "topic" },
        .finding_count = finding_values.len,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest_value.writeCanonical(allocator);
    errdefer allocator.free(manifest_bytes);
    var manifest = try committed_review.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    errdefer manifest.deinit();
    const patch_bytes = try allocator.dupe(u8, if (rename) finding_navigation_rename_patch else finding_navigation_patch);
    var patch_bytes_owned = true;
    errdefer if (patch_bytes_owned) allocator.free(patch_bytes);
    var projection: git_review.CommittedDiffProjection = .{ .target = target, .patch_bytes = patch_bytes };
    patch_bytes_owned = false;
    errdefer projection.deinit(allocator);
    const mode = [6]u8{ '1', '0', '0', '6', '4', '4' };
    const absent_mode = [6]u8{ '0', '0', '0', '0', '0', '0' };
    const endpoint_records = try allocator.alloc(git_review.CommittedDiffEndpointRecord, 2);
    endpoint_records[0] = .{
        .file_ordinal = 0,
        .status_bytes = try allocator.dupe(u8, if (rename) "R100" else "M"),
        .old_mode = mode,
        .new_mode = mode,
        .before = .{ .path_bytes = try allocator.dupe(u8, before_path), .object_oid = target.base_oid, .mode = mode, .is_blob = true },
        .after = .{ .path_bytes = try allocator.dupe(u8, after_path), .object_oid = target.head_oid, .mode = mode, .is_blob = true },
    };
    endpoint_records[1] = .{
        .file_ordinal = 1,
        .status_bytes = try allocator.dupe(u8, "A"),
        .old_mode = absent_mode,
        .new_mode = mode,
        .before = null,
        .after = .{ .path_bytes = try allocator.dupe(u8, "src/beta/b.zig"), .object_oid = target.head_oid, .mode = mode, .is_blob = true },
    };
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{ .target = target, .records = endpoint_records };
    defer endpoints.deinit(allocator);
    const validations = [_]git_review.CodeAnchorValidation{
        .{ .validated = target.head_oid },
        .{ .validated = target.base_oid },
        .{ .validated = target.head_oid },
        .{ .validated = target.head_oid },
        .{ .validated = target.head_oid },
    };
    var index = try finding_projection.build(allocator, .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest.value,
        .findings_bytes = findings_bytes,
        .finding_set = &findings.value,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = &validations,
    });
    errdefer index.deinit(allocator);
    return .{ .selection = .{
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
        .projection = projection,
        .finding_projection = index,
    }, .diff = .empty };
}

fn reviewHistoryPinnedBundle(
    allocator: std.mem.Allocator,
    snapshot: review_store.StoreSnapshot,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    with_finding: bool,
) !app_load.PinnedReviewLoadedBundle {
    const producer: committed_review.Producer = .{ .name = "reviewer", .model = "gpt-test" };
    const finding_values = [_]committed_review.Finding{.{
        .finding_id = .{ .bytes = "finding-stale" },
        .anchor = .{
            .path_bytes = "unchanged.zig",
            .side = .after,
            .start_line = 1,
            .end_line = 1,
            .content_digest = committed_review.Sha256Digest.hash("line\n"),
        },
        .severity = .warning,
        .title = "stale fixture",
        .body = "owned index cleanup",
    }};
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-20T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = if (with_finding) &finding_values else &.{},
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
        .finding_count = if (with_finding) 1 else 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest_value.writeCanonical(allocator);
    errdefer allocator.free(manifest_bytes);
    var manifest = try committed_review.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    errdefer manifest.deinit();
    const patch_text =
        "diff --git a/unchanged.zig b/unchanged.zig\n" ++
        "--- a/unchanged.zig\n" ++
        "+++ b/unchanged.zig\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+line\n";
    const patch_bytes = try allocator.dupe(u8, if (with_finding) patch_text else "");
    errdefer allocator.free(patch_bytes);
    var projection: git_review.CommittedDiffProjection = .{ .target = target, .patch_bytes = patch_bytes };
    errdefer projection.deinit(allocator);
    const mode = [6]u8{ '1', '0', '0', '6', '4', '4' };
    const endpoint_records = try allocator.alloc(git_review.CommittedDiffEndpointRecord, if (with_finding) 1 else 0);
    if (with_finding) endpoint_records[0] = .{
        .file_ordinal = 0,
        .status_bytes = try allocator.dupe(u8, "M"),
        .old_mode = mode,
        .new_mode = mode,
        .before = .{
            .path_bytes = try allocator.dupe(u8, "unchanged.zig"),
            .object_oid = target.base_oid,
            .mode = mode,
            .is_blob = true,
        },
        .after = .{
            .path_bytes = try allocator.dupe(u8, "unchanged.zig"),
            .object_oid = target.head_oid,
            .mode = mode,
            .is_blob = true,
        },
    };
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{
        .target = target,
        .records = endpoint_records,
    };
    defer endpoints.deinit(allocator);
    const one_validation = [_]git_review.CodeAnchorValidation{.{ .validated = target.head_oid }};
    var index = try finding_projection.build(allocator, .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest.value,
        .findings_bytes = findings_bytes,
        .finding_set = &findings.value,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = if (with_finding) &one_validation else &.{},
    });
    errdefer index.deinit(allocator);

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
            .projection = projection,
            .finding_projection = index,
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
