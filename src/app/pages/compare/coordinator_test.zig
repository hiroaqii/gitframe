//! Owner-local tests for Compare coordination.

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
const git_refs = @import("../../../git/refs.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const compare_page = @import("../compare.zig");
const compare_coordinator = @import("coordinator.zig");

const CompareLoadFinished = app_load.CompareLoadFinished;
const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const CompareBranchListLoadTask = app_load.CompareBranchListLoadTask(app_message.Msg);

const TestApp = struct {
    allocator: ?std.mem.Allocator = null,
    active_page: page.Id = .compare,
    repo_session: repo_session.State = .{},
    pages: struct { compare: compare_page.ComparePageState = .{} } = .{},
    layout: diff_surface.Layout = .{ .width = 100, .height = 30 },

    const Msg = app_message.Msg;

    fn controller(self: *TestApp) compare_coordinator.Controller {
        return .{
            .page_state = &self.pages.compare,
            .repo = self.repo_session.view(),
            .layout = self.layout,
            .env_map = null,
        };
    }

    fn update(self: *TestApp, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .reload => try self.controller().refresh(ctx),
            .compare => |compare_msg| {
                var outcome = try self.controller().update(ctx, compare_msg);
                defer outcome.deinit(ctx.allocator());
            },
            .load_finished => |finished| switch (finished) {
                .compare => |compare_finished| switch (compare_finished) {
                    .source => |source| _ = try self.controller().finishLoad(ctx, source),
                    .branch_list => |branches| _ = self.controller().finishBranchList(ctx.allocator(), branches),
                },
                else => unreachable,
            },
            else => unreachable,
        }
    }
};

test "diff wheel comfort routes through Compare and recenters an edge cursor" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .pages = .{ .compare = .{
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
    defer app.pages.compare.deinit(allocator);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    const old_scroll = app.pages.compare.viewer.diff_scroll;
    const navigation = app.controller().navigation();
    var update_adapter = navigation.updateAdapter();
    const body = update_adapter.bodyController();
    const visible_rows = body.view().view.diffVisibleRows();
    app.pages.compare.viewer.diff_cursor = body.view().selectedCoordinateAtOffset(old_scroll) orelse
        return error.ExpectedCoordinate;

    try app.update(.{ .compare = .{ .shared = .mouse_diff_wheel_down } }, &ctx);

    var result_adapter = app.controller().navigation().updateAdapter();
    const result_body = result_adapter.bodyController();
    try std.testing.expectEqual(diff_surface.Focus.diff, app.pages.compare.viewer.focus);
    try std.testing.expectEqual(old_scroll + 1, app.pages.compare.viewer.diff_scroll);
    try std.testing.expectEqual(
        app.pages.compare.viewer.diff_scroll + visible_rows / 2,
        result_body.view().selectedDiffCursorOffset().?,
    );
}

test "Compare coordinator returns shared drag auto-scroll outcome" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .pages = .{ .compare = .{
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
    defer app.pages.compare.deinit(allocator);
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
    try std.testing.expectEqual(@as(usize, 1), app.pages.compare.viewer.diff_scroll);
    const selection = app.pages.compare.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(selection.side == .old);
    try std.testing.expectEqual(@as(usize, 1), selection.focus.line_index);
}

test "Compare reload retries user intent and preserves accepted display on failure" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    if (app.pages.compare.base_target) |*target| target.deinit(allocator);
    app.pages.compare.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/topic"),
        .display_name = try allocator.dupe(u8, "topic"),
        .kind = .local,
    };

    try app.update(.reload, &ctx);
    const failed_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqualStrings("refs/heads/topic", failed_task.target.?.full_ref);
    const failed_identity = failed_task.identity;
    const failed_generation = failed_task.generation;
    try abandonSingleQueuedTask(&ctx, allocator);
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppBasisFailureFinished(
        allocator,
        failed_identity,
        failed_generation,
        "topic",
    ) } } }, &ctx);

    try std.testing.expectEqualStrings("main", app.pages.compare.basis.?.base.display_name);
    try std.testing.expect(app.pages.compare.load.state == .loaded);
    try std.testing.expectEqualStrings("topic", app.pages.compare.basis_failure.?.attempted.display_name);
    try std.testing.expectEqualStrings("topic", app.pages.compare.base_target.?.display_name);

    try app.update(.reload, &ctx);
    const retry_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqualStrings("refs/heads/topic", retry_task.target.?.full_ref);
    try std.testing.expect(app.pages.compare.basis_failure == null);
    try std.testing.expectEqualStrings("main", app.pages.compare.basis.?.base.display_name);
}

test "Compare refresh restores its anchor after atomic replacement" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    app.pages.compare.viewer.diff_cursor = .{ .hunk_header = 0 };
    const selected_before = app.pages.compare.viewer.selected_target.?;

    try app.update(.reload, &ctx);
    try std.testing.expect(app.pages.compare.refresh_anchor != null);
    const stale_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const stale_identity = stale_task.identity;
    const stale_generation = stale_task.generation;
    try app.update(.reload, &ctx);
    const current_task: *CompareLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const identity = current_task.identity;
    const generation = current_task.generation;
    try std.testing.expectEqual(@as(usize, 2), abandonQueuedTasks(&ctx, allocator));
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        stale_identity,
        stale_generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expect(app.pages.compare.refresh_anchor != null);
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
        allocator,
        identity,
        generation,
        'a',
        'b',
    ) } } }, &ctx);

    try std.testing.expect(app.pages.compare.refresh_anchor == null);
    try std.testing.expectEqual(selected_before, app.pages.compare.viewer.selected_target.?);
    try std.testing.expectEqual(
        diff_view_model.BodyCoordinate{ .hunk_header = 0 },
        app.pages.compare.viewer.diff_cursor,
    );
}

test "Compare app route retains viewed marks only for an unchanged oid pair" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { base: u8, head: u8, retained: bool }{
        .{ .base = 'a', .head = 'b', .retained = true },
        .{ .base = 'd', .head = 'b', .retained = false },
        .{ .base = 'a', .head = 'e', .retained = false },
    };
    for (cases) |case| {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .compare,
            .repo_session = .{
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, "/repo") },
            },
        };
        defer app.pages.compare.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        _ = app.pages.compare.activate(app.repo_session.repo_epoch);
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

        const initial = app.pages.compare.beginRefresh().?;
        try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
            allocator,
            initial.identity,
            initial.generation,
            'a',
            'b',
        ) } } }, &ctx);
        const first_loaded = switch (app.pages.compare.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedCompare,
        };
        try app.pages.compare.reviewed_store.set(allocator, "/repo", first_loaded.document.files[0], true);
        first_loaded.reviewed_files[0] = true;

        const replacement = app.pages.compare.beginRefresh().?;
        try app.update(.{ .load_finished = .{ .compare = .{ .source = try compareAppLoadedFinished(
            allocator,
            replacement.identity,
            replacement.generation,
            case.base,
            case.head,
        ) } } }, &ctx);
        const second_loaded = switch (app.pages.compare.load.state) {
            .loaded => |*session| &session.loaded,
            else => return error.ExpectedLoadedCompare,
        };
        try std.testing.expectEqual(case.retained, second_loaded.reviewed_files[0]);
    }
}

test "Compare picker rejects replaced and closed generations through the App route" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .compare = .open_base_picker }, &ctx);
    const first: *CompareBranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const first_identity = first.identity;
    const first_generation = first.generation;
    try app.update(.{ .compare = .open_base_picker }, &ctx);
    const second: *CompareBranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const second_identity = second.identity;
    const second_generation = second.generation;
    try std.testing.expect(second_generation > first_generation);

    try app.update(.{ .load_finished = .{ .compare = .{ .branch_list = .{
        .identity = first_identity,
        .generation = first_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "stale", .oid = "1111111111111111111111111111111111111111" }}),
    } } } }, &ctx);
    try std.testing.expect(app.pages.compare.base_picker.accepted == null);
    try app.update(.{ .load_finished = .{ .compare = .{ .branch_list = .{
        .identity = second_identity,
        .generation = second_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "accepted", .oid = "2222222222222222222222222222222222222222" }}),
    } } } }, &ctx);
    try std.testing.expectEqualStrings("accepted", app.pages.compare.base_picker.accepted.?.branches[0].name);

    try app.update(.{ .compare = .close_base_picker }, &ctx);
    try std.testing.expect(app.pages.compare.base_picker.accepted == null);
    try app.update(.{ .load_finished = .{ .compare = .{ .branch_list = .{
        .identity = second_identity,
        .generation = second_generation,
        .result = try branchListForTest(allocator, &.{.{ .name = "closed", .oid = "3333333333333333333333333333333333333333" }}),
    } } } }, &ctx);
    try std.testing.expect(app.pages.compare.base_picker.accepted == null);
}

test "Compare load route admits failure intent through the Compare owner" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{
        .repo_session = .{ .repo_epoch = 12 },
    };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    const request = app.pages.compare.beginRefresh().?;
    var tc: chasen.testing.TestCtx(TestApp.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .load_finished = .{ .compare = .{ .source = .{
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

    try std.testing.expectEqualStrings("gone", app.pages.compare.basis_failure.?.attempted.display_name);
}

const compare_app_test_diff =
    "diff --git a/src/compare.zig b/src/compare.zig\n" ++
    "--- a/src/compare.zig\n" ++
    "+++ b/src/compare.zig\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

fn compareAppTestOid(byte: u8) diff_basis.Oid {
    var oid: diff_basis.Oid = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn compareAppLoadedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base_byte: u8,
    head_byte: u8,
) !CompareLoadFinished {
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
                    .oid = compareAppTestOid(base_byte),
                },
                .head_display = head_display,
                .merge_base_oid = compareAppTestOid(base_byte),
                .head_oid = compareAppTestOid(head_byte),
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, compare_app_test_diff) },
        } },
    };
}

fn compareAppBasisFailureFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    name: []const u8,
) !CompareLoadFinished {
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
