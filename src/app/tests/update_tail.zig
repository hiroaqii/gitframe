//! Root integration tests for cross-owner update-tail ordering.

const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_auto_reload = @import("../auto_reload.zig");
const canonical = @import("canonical_publication.zig");
const app_test_support = @import("../test_support.zig");
const app_load = @import("../load.zig");
const app_input = @import("../input.zig");
const app_message = @import("../message.zig");
const app_state = @import("../state.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");
const app_changes_projection = @import("../changes_projection.zig");
const app_shell_layout = @import("../shell_layout.zig");
const page = @import("../page.zig");
const page_link = @import("../page_link.zig");
const repo_session = @import("../repo_session.zig");
const review_page = @import("../pages/review.zig");
const repository_page = @import("../pages/repository.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const repository_tasks = @import("../pages/repository/tasks.zig");
const changes_page = @import("../pages/changes.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const context = @import("../../context.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const diff_file = @import("../../diff/file.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_presentation_identity = @import("../../diff/presentation_identity.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const file_tree = @import("../../file_tree.zig");
const git_refs = @import("../../git/refs.zig");
const git_read = @import("../../git/read.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const repo_root_capability = @import("../../repo/root_capability.zig");
const review_session = @import("../../review_session/session.zig");
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");

const App = app_mod.App;
const OverlayKind = app_state.OverlayKind;
const LoadedDiff = @import("../../loaded_diff.zig").LoadedDiff;
const loaded_diff = @import("../../loaded_diff.zig");
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const ReviewLoadFinished = app_load.ReviewLoadFinished;
const ReviewLoadTask = app_load.ReviewLoadTask(app_message.Msg);
const ReviewBranchListFinished = app_load.ReviewBranchListFinished;
const ReviewBranchListLoadTask = app_load.ReviewBranchListLoadTask(app_message.Msg);
const RepositoryManifestTask = repository_tasks.ManifestTask(app_message.Msg);
const RepositoryBranchTask = repository_tasks.BranchTask(app_message.Msg);
const RepositoryDocumentTask = repository_tasks.DocumentTask(app_message.Msg);
const RepositorySyntaxTask = repository_tasks.SyntaxTask(app_message.Msg);
const RepositoryChangeMapTask = repository_tasks.ChangeMapTask(app_message.Msg);

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

const canonicalPublicationTestApp = canonical.canonicalPublicationTestApp;
const canonicalPublicationStagedOnlyReuseCandidate = canonical.canonicalPublicationStagedOnlyReuseCandidate;
const takeCanonicalPublicationReads = canonical.takeCanonicalPublicationReads;
const startCanonicalPublicationWatch = canonical.startCanonicalPublicationWatch;
const finishCanonicalPublicationStatus = canonical.finishCanonicalPublicationStatus;
const finishCanonicalPublicationBranch = canonical.finishCanonicalPublicationBranch;

const FakeRealClock = struct {
    seconds: i64,
    resolution_ns: i96 = 1,
    available: bool = true,
    samples: usize = 0,
    vtable: std.Io.VTable,

    fn init(seconds: i64) FakeRealClock {
        return .{ .seconds = seconds, .vtable = std.testing.io.vtable.* };
    }

    fn io(self: *FakeRealClock) std.Io {
        self.vtable.now = now;
        self.vtable.clockResolution = resolution;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        std.debug.assert(clock == .real);
        const self: *FakeRealClock = @ptrCast(@alignCast(userdata.?));
        self.samples += 1;
        return .{ .nanoseconds = @as(i96, self.seconds) * std.time.ns_per_s };
    }

    fn resolution(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
        std.debug.assert(clock == .real);
        const self: *FakeRealClock = @ptrCast(@alignCast(userdata.?));
        if (!self.available) return error.ClockUnavailable;
        return .{ .nanoseconds = self.resolution_ns };
    }
};

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

fn beginAcceptedTestAction(app: *App, kind: @import("../actions.zig").ActionKind) @import("../actions.zig").PendingAction {
    const pending: @import("../actions.zig").PendingAction = .{ .generation = 1, .kind = kind };
    action_lifecycle.testing.installAccepted(&app.action_runtime, pending);
    return pending;
}
test "user actions clear previous ephemeral status" {
    var app: App = .{};
    app.status.set("staged: {s}", .{"src/app.zig"});

    try app.update(.{ .changes = .toggle_focus }, undefined);

    try std.testing.expectEqualStrings("", app.status.text());
}

test "system events keep previous ephemeral status" {
    var app: App = .{};
    app.status.set("staged: {s}", .{"src/app.zig"});

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, undefined);

    try std.testing.expectEqualStrings("staged: src/app.zig", app.status.text());
}

test "Repository path history known unavailable and stale completions preserve primary diagnostics" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .repository };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    for (0..2) |case| {
        app.status.set("root diagnostic", .{});
        app.pages.repository.status.set("Repository diagnostic", .{});
        const outcome: git_read.RepositoryPathHistoryOutcome = if (case == 0)
            .{ .known = .{
                .head = .{ .oid = try allocator.dupe(u8, "0123456789abcdef0123456789abcdef01234567") },
                .fact = .uncommitted,
            } }
        else
            .unavailable;
        try app.update(.{ .repository = .{ .path_history_finished = .{
            .identity = .{ .origin = .repository, .repo_epoch = 99, .activation_id = 88 },
            .root_identity = .{ .device = 7, .inode = 6 },
            .manifest_revision = 5,
            .generation = 4,
            .path = try allocator.dupe(u8, "stale.zig"),
            .outcome = outcome,
        } } }, &ctx);
        try std.testing.expectEqualStrings("root diagnostic", app.status.text());
        try std.testing.expectEqualStrings("Repository diagnostic", app.pages.repository.status.text());
    }

    try app.update(.{ .repository = .move_down }, &ctx);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
}

test "git action spinner ticks keep previous ephemeral status" {
    var app: App = .{};
    app.status.set("pushing: {s}", .{"main -> origin/main"});
    _ = beginAcceptedTestAction(&app, .push);
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);

    try app.update(.git_action_spinner_tick, undefined);

    try std.testing.expectEqualStrings("pushing: main -> origin/main", app.status.text());
    try std.testing.expectEqual(@as(u8, 1), action_lifecycle.testing.spinnerTick(&app.action_runtime));
}

test "git action spinner starts when pending action is visible after update" {
    var app: App = .{};
    _ = beginAcceptedTestAction(&app, .push);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, &tc.ctx);

    try std.testing.expect(action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
}

test "git action spinner self-cancels stale ticks without redraw" {
    var app: App = .{};
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.git_action_spinner_tick, &tc.ctx);

    try std.testing.expect(!action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(u8, 0), action_lifecycle.testing.spinnerTick(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expect(tc.redrawSuppressed());
}

test "grouped result messages keep previous ephemeral status" {
    try std.testing.expect(app_message.keepsEphemeralStatus(.{ .load_finished = undefined }));
    try std.testing.expect(app_message.keepsEphemeralStatus(.{ .action_finished = undefined }));
    try std.testing.expect(app_message.keepsEphemeralStatus(.git_action_spinner_tick));
}

test "branch time pickers sample one real-clock snapshot at every non-skipped redraw tail" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .review };
    defer app.pages.review.deinit(allocator);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    _ = app.pages.review.beginBasePicker(allocator).?;
    var clock = FakeRealClock.init(1_700_000_059);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = clock.io() };

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_059), app.pages.review.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 1), clock.samples);

    // An unrelated Review source completion crosses the 59s -> 1m boundary
    // through the same common tail instead of a picker-specific handler.
    clock.seconds += 1;
    const refresh = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        refresh.identity,
        refresh.generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_060), app.pages.review.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    // A stale list terminal resolves to skip and therefore does not sample.
    clock.seconds += 1;
    ctx.resetRedrawSuppressed();
    try app.update(.{ .load_finished = .{ .review = .{ .branch_list = .{
        .identity = refresh.identity,
        .generation = app.pages.review.base_picker.generation + 1,
        .result = .empty,
    } } } }, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(?i64, 1_700_000_060), app.pages.review.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    // Hidden and idle picker states do not consult the wall clock.
    app.active_page = .changes;
    try app.update(.{ .terminal_resized = .{ .width = 100, .height = 24 } }, &ctx);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);
    app.active_page = .review;
    app.pages.review.closeBasePicker(allocator);
    try app.update(.{ .terminal_resized = .{ .width = 90, .height = 20 } }, &ctx);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    var repo_root = "/repo".*;
    var branch = "main".*;
    var oid = "abc123".*;
    var branches = [_]app_state.BranchSwitchItem{.{
        .name = &branch,
        .oid = &oid,
        .current = true,
        .tip_committer_unix = 1_700_000_000,
    }};
    app.remote_workflow.branch_switch = .{
        .repo_root = &repo_root,
        .current_branch = &branch,
        .current_oid = &oid,
        .branches = &branches,
    };
    app.overlay.openSwitchBranch();
    app.active_page = .changes;
    clock.seconds += 1;
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_062), app.remote_workflow.branch_switch.render_now_unix);
    try std.testing.expectEqual(@as(usize, 3), clock.samples);
}

test "branch time pickers fail closed for unavailable and zero-resolution real clocks" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .review };
    defer app.pages.review.deinit(allocator);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    _ = app.pages.review.beginBasePicker(allocator).?;
    var clock = FakeRealClock.init(1_700_000_000);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = clock.io() };

    clock.available = false;
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    try std.testing.expect(app.pages.review.base_picker.render_now_unix == null);
    try std.testing.expectEqual(@as(usize, 0), clock.samples);

    clock.available = true;
    clock.resolution_ns = 0;
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx);
    try std.testing.expect(app.pages.review.base_picker.render_now_unix == null);
    try std.testing.expectEqual(@as(usize, 0), clock.samples);

    var repo_root = "/repo".*;
    var branch = "main".*;
    var oid = "abc123".*;
    var branches = [_]app_state.BranchSwitchItem{.{
        .name = &branch,
        .oid = &oid,
        .current = true,
        .tip_committer_unix = 1_700_000_000,
    }};
    app.pages.review.closeBasePicker(allocator);
    app.remote_workflow.branch_switch = .{
        .repo_root = &repo_root,
        .current_branch = &branch,
        .current_oid = &oid,
        .branches = &branches,
    };
    app.overlay.openSwitchBranch();
    app.active_page = .changes;
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx);
    try std.testing.expect(app.remote_workflow.branch_switch.render_now_unix == null);
    try std.testing.expectEqual(@as(usize, 0), clock.samples);
}

test "modal transitions clear previous ephemeral status" {
    var app: App = .{};
    app.status.set("staged: {s}", .{"src/app.zig"});

    try app.update(.open_help, undefined);

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);
}

test "repo switch clears pending reload anchor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "repo", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(root);
    var app: App = .{
        .pages = .{ .changes = .{
            .pending_reload = .{
                .generation = 9,
                .kind = .manual,
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
    };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.deinit(allocator);

    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, root),
        0,
        .external_selection,
    ));

    try std.testing.expect(app.pages.changes.pending_reload == null);
}

fn activateChanges(app: *App) u64 {
    const source_member: changes_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        switch (app.pages.changes.load.state) {
            .loaded, .empty => .immutable,
            .loading => .pending,
            .failed => .failed,
            .idle => .pending,
        }
    else
        .pending;
    const auxiliary: changes_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(app.config.source) and app.repo_session.view().activeRoot() != null) .pending else .unavailable;
    return app.pages.changes.activation.activate(
        app.repo_session.view().epoch(),
        source_member,
        auxiliary,
        auxiliary,
    );
}

fn changesNavigationView(app: *const App) changes_navigation.View {
    const body = app_shell_layout.compute(
        app.terminal_size,
        .{ .page_bar_visible = true },
    ).bodySize();
    return .{
        .page = &app.pages.changes,
        .repo_root = app.repo_session.view().activeRoot(),
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = body.width, .height = body.height },
    };
}

fn changesNavigation(app: *App) changes_navigation.Controller {
    const body = app_shell_layout.compute(
        app.terminal_size,
        .{ .page_bar_visible = true },
    ).bodySize();
    return .{
        .page = &app.pages.changes,
        .repo_root = app.repo_session.view().activeRoot(),
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = body.width, .height = body.height },
        .diagnostics = .{ .target = &app.pages.changes.status },
    };
}

fn changesReload(app: *App) changes_reload.Controller {
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .navigation = changesNavigation(app),
        .source = app.config.source,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
    };
}

fn repoSession(app: *App) repo_session.Controller {
    return .{
        .state = &app.repo_session,
        .status = &app.status,
        .active_page = app.active_page,
        .source = app.config.source,
        .home = null,
        .action_pending = app.action_runtime.view().hasPending(),
        .changes = .{ .page = &app.pages.changes, .navigation = changesNavigation(app), .reload = changesReload(app) },
        .repository = .{ .page = &app.pages.repository },
        .review = .{ .page = &app.pages.review },
        .shell = app.remote_workflow.repositoryInvalidationPort(&app.overlay),
    };
}

fn commitDiscovery(
    app: *App,
    allocator: std.mem.Allocator,
    result: repo_discovery.DiscoveryResult,
    active_index: usize,
    origin: repo_session.CommitOrigin,
) !repo_session.CommitOutcome {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    return repoSession(app).commitDiscovered(&ctx, result, active_index, origin);
}

test "Review completion defers as one bundle during drag and applies afterward" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .review };
    defer app.pages.review.deinit(allocator);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const initial = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    app.pages.review.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "b/src/compare.zig" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    const replacement = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        replacement.identity,
        replacement.generation,
        'd',
        'e',
    ) } } }, &ctx);

    try std.testing.expect(app.pages.review.deferred_load_apply != null);
    try std.testing.expectEqualStrings(reviewAppTestOid('b').slice(), app.pages.review.basis.?.head_oid.slice());
    app.pages.review.selection_owner = .none;
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(app.pages.review.deferred_load_apply == null);
    try std.testing.expectEqualStrings(reviewAppTestOid('e').slice(), app.pages.review.basis.?.head_oid.slice());
}

test "repository commitment resets Review and refreshes the new physical root" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .review,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.review.activate(0);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const initial = app.pages.review.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .review = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx);
    try std.testing.expect(app.pages.review.basis != null);

    const changes_activation = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    const discovery_generation = app.pages.changes.load.beginRepoDiscovery();
    app.pages.changes.load.state = .loading;
    try app.update(.{ .load_finished = .{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(0, changes_activation),
        .generation = discovery_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.b) },
    } } } }, &ctx);

    try std.testing.expectEqual(@as(u64, 1), app.repo_session.view().epoch());
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(app.pages.review.basis == null);
    try std.testing.expect(app.pages.review.base_target == null);
    try std.testing.expect(app.pages.review.activation.state == .active);
    try std.testing.expectEqual(@as(u64, 1), app.pages.review.activation.state.active.repo_epoch);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const task: *ReviewLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expect(task.root.identity.eql(app.repo_session.view().activeIdentity().?));
}

test "repository activation and manual reload route to page-owned manifest tasks" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = roots.a,
                .canonical_root = roots.a,
            } } },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer if (app.repo_session.repo_state.root) |*root| root.deinit();
    defer app.pages.repository.deinit(std.testing.allocator);
    _ = activateChanges(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingRepositoryTasks(&ctx, std.testing.allocator);

    try app.update(.{ .switch_page = .repository }, &ctx);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
    const first: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqual(page.Id.repository, first.request.identity.origin);
    try std.testing.expectEqual(app.repo_session.repo_epoch, first.request.identity.repo_epoch);
    const first_generation = first.request.generation;
    const first_branch: *RepositoryBranchTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    const first_branch_generation = first_branch.request.generation;
    try std.testing.expectEqual(first.request.identity, first_branch.request.identity);

    try app.update(.reload, &ctx);
    try std.testing.expectEqual(@as(u8, 4), ctx._pending_tasks_with_len);
    const second: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    try std.testing.expect(second.request.generation > first_generation);
    try std.testing.expectEqual(second.request.generation, app.pages.repository.pending_generation.?);
    const second_branch: *RepositoryBranchTask = @ptrCast(@alignCast(ctx._pending_tasks_with[3].ctx));
    try std.testing.expect(second_branch.request.generation > first_branch_generation);
    try std.testing.expectEqual(second_branch.request.generation, app.pages.repository.branch.pending.?.generation);
}

test "changes repository transition active repository replacement rejects old owner and result" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    app.pages.repository.activate(app.repo_session.repo_epoch, app.repo_session.view().activeIdentity());
    const root_a_identity = app.repo_session.view().activeIdentity().?;
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_a_identity));
    app.pages.repository.selected_path = "retained.zig";
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.repo_session.repo_epoch,
        app.repo_session.view().activeIdentity().?,
        .{ .location = .{ .path = "pending.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingRepositoryTasks(&ctx, allocator);

    try app.update(.reload, &ctx);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
    const old_task: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    const old_identity = old_task.request.identity;
    const old_root_identity = old_task.request.root.identity;
    const old_generation = old_task.request.generation;
    try std.testing.expectEqual(page.Id.repository, old_identity.origin);
    try std.testing.expectEqual(app.pages.repository.repo_epoch, old_identity.repo_epoch);
    try std.testing.expectEqual(app.pages.repository.activation_id, old_identity.activation_id);
    try std.testing.expectEqual(app.pages.repository.generation, old_generation);
    try std.testing.expectEqual(old_generation, app.pages.repository.pending_generation.?);
    try std.testing.expect(old_root_identity.eql(root_a_identity));
    try std.testing.expectEqualStrings(roots.a, old_task.request.root_path);

    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    const root_b_identity = app.repo_session.view().activeIdentity().?;
    try std.testing.expect(!root_a_identity.eql(root_b_identity));
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.repo_session.repo_epoch);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_b_identity));
    try std.testing.expect(app.pages.repository.selected_path == null);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expect(app.pages.repository.pending_generation == null);
    try std.testing.expect(app.pages.repository.needs_revalidation);
    try std.testing.expect(app.pages.repository.wantsManifestRequest());

    try app.update(.{ .repository = .{ .manifest_finished = .{
        .identity = old_identity,
        .root_identity = old_root_identity,
        .generation = old_generation,
        .result = .{ .failed_static = "stale old manifest" },
    } } }, &ctx);

    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.pages.repository.repo_epoch);
    try std.testing.expect(app.pages.repository.root_identity.?.eql(root_b_identity));
    try std.testing.expect(app.pages.repository.bundle == null);
    try std.testing.expect(app.pages.repository.selected_path == null);
    try std.testing.expect(app.pages.repository.incoming == .none);
    const replacement_generation = app.pages.repository.pending_generation orelse
        return error.ExpectedReplacementManifest;
    try std.testing.expect(!app.pages.repository.needs_revalidation);
    try std.testing.expect(!app.pages.repository.wantsManifestRequest());
    try std.testing.expectEqual(@as(u8, 4), ctx._pending_tasks_with_len);
    const replacement_task: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    try std.testing.expectEqual(replacement_generation, replacement_task.request.generation);
    try std.testing.expectEqualStrings(roots.b, replacement_task.request.root_path);
    try std.testing.expect(replacement_task.request.root.identity.eql(root_b_identity));
    try std.testing.expectEqual(@as(usize, 0), app.pages.repository.status.text().len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "changes repository transition post-commit manifest start failures stay on Repository" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    const cases = [_]struct {
        fail_index: usize,
        generation: u64,
        status: []const u8,
    }{
        .{
            .fail_index = 0,
            .generation = 0,
            .status = "Could not prepare repository manifest: OutOfMemory",
        },
        .{
            .fail_index = 1,
            .generation = 1,
            .status = "Could not start repository manifest task",
        },
    };

    for (cases) |case| {
        var app: App = .{
            // The handoff succeeds through the application allocator. Only
            // destination task preparation uses the failing Ctx allocator,
            // making this a post-commit failure rather than a prepare error.
            .allocator = allocator,
            .repo_session = .{
                .repo_epoch = 7,
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
            .config = .{ .source = .unstaged },
            .pages = .{ .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
            } },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        acceptTestSource(&app);
        const changes_activation = app.pages.changes.activation.state.active.activation_id;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = case.fail_index });
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(error.OutOfMemory, app.update(.{ .switch_page = .repository }, &ctx));

        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expect(app.pages.changes.activation.state == .inactive);
        try std.testing.expectEqual(changes_activation, app.pages.changes.activation.next_activation_id);
        try std.testing.expect(app.pages.repository.active);
        try std.testing.expectEqual(@as(u64, 1), app.pages.repository.activation_id);
        const unavailable = app.pages.repository.incomingUnavailable().?;
        try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
        try std.testing.expectEqualStrings("a", unavailable.path);
        try std.testing.expectEqual(case.generation, app.pages.repository.generation);
        try std.testing.expect(app.pages.repository.pending_generation == null);
        try std.testing.expectEqualStrings(case.status, app.pages.repository.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_len);
    }
}

test "repository incoming viewport scroll App immediate and deferred routes use current body size" {
    const allocator = std.testing.allocator;
    const Route = enum { keyboard, page_bar, deferred_manifest };
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    for ([_]Route{ .keyboard, .page_bar, .deferred_manifest }) |route| {
        var app: App = .{
            .allocator = allocator,
            .repo_session = .{
                .repo_epoch = 4,
            },
            .terminal_size = .{ .width = 120, .height = 12 },
            .config = .{ .source = .unstaged },
            .pages = .{ .changes = .{
                .load = app_test_support.loadState(repositoryIncomingViewportChangesDiffForTest()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 1 },
                    .selected_node = 3,
                },
            } },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, roots.a);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        const identity = app.repo_session.view().activeIdentity().?;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer clearPendingRepositoryTasks(&ctx, allocator);
        try std.testing.expectEqual(
            chasen.Size{ .width = 118, .height = 7 },
            app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize(),
        );

        switch (route) {
            .keyboard, .page_bar => {
                app.pages.repository.repo_epoch = 4;
                app.pages.repository.root_identity = identity;
                app.pages.repository.bundle = try repositoryIncomingViewportBundleForTest(allocator);
                app.pages.repository.load_state = .loaded;
                app.pages.repository.manifest_revision = 2;
                app.pages.repository.viewer = .{
                    .tree_cursor = 5,
                    .tree_vertical_scroll = 99,
                };
                app.pages.repository.selected_path =
                    app.pages.repository.bundle.?.tree.filePath("src/app.zig", .all).?;
                acceptTestSource(&app);
                const msg = if (route == .keyboard)
                    app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }) orelse
                        return error.ExpectedPageSwitch
                else blk: {
                    const repository_tab = page.tab(.repository);
                    const bar = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).page_bar orelse return error.ExpectedPageBar;
                    break :blk app.handleEvent(app_test_support.mouseEvent(
                        bar.col + repository_tab.col,
                        bar.row,
                        .left,
                    )) orelse return error.ExpectedPageSwitch;
                };
                try app.update(msg, &ctx);
            },
            .deferred_manifest => {
                app.active_page = .repository;
                app.pages.repository = .{
                    .initialized = true,
                    .active = true,
                    .activation_id = 2,
                    .repo_epoch = 4,
                    .root_identity = identity,
                    .generation = 7,
                    .pending_generation = 7,
                    .load_state = .loading,
                    .viewer = .{ .tree_vertical_scroll = 99 },
                };
                var incoming = try page_link.RepositoryIncoming.initOwned(
                    allocator,
                    4,
                    identity,
                    .{ .location = .{ .path = "src/app/pages/repository.zig" } },
                );
                app.pages.repository.acceptIncoming(allocator, &incoming);
                try app.update(.{ .repository = .{ .manifest_finished = .{
                    .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
                    .root_identity = identity,
                    .generation = 7,
                    .result = .{ .loaded = try repositoryIncomingViewportBundleForTest(allocator) },
                } } }, &ctx);
            },
        }

        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expectEqualStrings("src/app/pages/repository.zig", app.pages.repository.selected_path.?);
        try std.testing.expectEqual(@as(usize, 4), app.pages.repository.viewer.tree_cursor);
        try std.testing.expectEqual(@as(usize, 0), app.pages.repository.viewer.tree_vertical_scroll);
        try expectRepositoryProjectedPathForTest(&app.pages.repository, 1, "src");
        try expectRepositoryProjectedPathForTest(&app.pages.repository, 4, "src/app/pages/repository.zig");
    }
}

test "changes repository transition unavailable path is not replayed after reload" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var initial_loaded = app_test_support.loadedDiffOne();
    initial_loaded.text = "old";
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(initial_loaded),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
                    .diff_cursor = .{ .metadata = 0 },
                    .diff_scroll = 5,
                },
            },
            .repository = .{
                .active = true,
                .repo_epoch = 7,
                .selected_path = "b",
            },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity().?;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.update(.{ .switch_page = .changes }, &ctx);

    try std.testing.expectEqualStrings("Repository file is not part of the current Changes", app.status.text());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    const diff_task: *DiffLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    var replacement = app_test_support.loadedDiffTwo();
    replacement.text = "new";
    try app.update(.{ .load_finished = .{ .changes = .{ .source = .{
        .identity = diff_task.identity,
        .generation = diff_task.generation,
        .background_cycle_id = diff_task.background_cycle_id,
        .result = .{ .loaded = .{
            .arena = .init(allocator),
            .loaded = replacement,
        } },
    } } } }, &ctx);
    try app.update(.{ .load_finished = .{ .changes = .{ .status = .{
        .identity = status_task.identity,
        .read_epoch = status_task.read_epoch,
        .generation = status_task.generation,
        .background_cycle_id = status_task.background_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .empty,
    } } } }, &ctx);

    const reloaded = changesNavigationView(&app).activeLoadedDiffConst().?;
    try std.testing.expectEqual(@as(usize, 2), reloaded.document.files.len);
    try std.testing.expect(app.pages.changes.viewer.selected_node < reloaded.tree.nodes.len);
    try std.testing.expectEqualStrings(
        "a",
        reloaded.tree.nodes[app.pages.changes.viewer.selected_node].path,
    );
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
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
                    .oid = reviewAppTestOid(base_byte),
                },
                .head_display = head_display,
                .merge_base_oid = reviewAppTestOid(base_byte),
                .head_oid = reviewAppTestOid(head_byte),
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
    app: *App,
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

fn repositoryLiveSelectionForTest() repository_selection.DragSelection {
    return .init(
        .{
            .repo_epoch = 1,
            .root_identity = .{ .device = 2, .inode = 3 },
            .path = "main.zig",
            .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
        },
        .character,
        .{ .line_index = 0, .leading_byte = 0, .trailing_byte = 1 },
    );
}

fn repositoryHeaderSelectionForTest() repository_selection.SourceHeaderPathSelection {
    return .{ .identity = .{
        .repo_epoch = 1,
        .activation_id = 4,
        .root_identity = .{ .device = 2, .inode = 3 },
        .manifest_revision = 5,
        .path = "main.zig",
    } };
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

fn repositoryIncomingViewportChangesDiffForTest() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &repository_incoming_viewport_changes_files },
        .file_text_eligibility = &repository_incoming_viewport_changes_eligibility,
        .tree = .{ .nodes = &repository_incoming_viewport_changes_tree_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn repositoryIncomingViewportBundleForTest(allocator: std.mem.Allocator) !repository_tasks.Bundle {
    const repository_manifest = @import("../../repository/manifest.zig");
    const repository_tree = @import("../../repository/tree.zig");
    var document = try repository_manifest.parseOwned(
        allocator,
        try allocator.dupe(u8, "src/app.zig\x00src/app/pages/repository.zig\x00"),
    );
    errdefer document.deinit(allocator);
    return .{
        .document = document,
        .tree = try repository_tree.Tree.build(allocator, &document),
    };
}

fn expectRepositoryProjectedPathForTest(
    state: *const repository_page.RepositoryPageState,
    visible_index: usize,
    expected_path: []const u8,
) !void {
    const tree = &state.bundle.?.tree;
    const target = state.tree_projection.targetAt(tree, visible_index) orelse
        return error.ExpectedProjectedPath;
    switch (target) {
        .repo_root => return error.ExpectedManifestPath,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            expected_path,
            tree.nodes[node_index].path,
        ),
    }
}

fn acceptTestSource(app: *App) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn syncTestActivation(app: *App) void {
    const source: changes_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        .immutable
    else if (app.pages.changes.auto_reload.sourceIsActionable())
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

fn clearPendingRepositoryTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn clearPendingStatusAndDiffTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

const repository_incoming_viewport_changes_files = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/src/app.zig b/src/app.zig",
        .old_path = "a/src/app.zig",
        .new_path = "b/src/app.zig",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    },
    .{
        .header = "diff --git a/src/app/pages/repository.zig b/src/app/pages/repository.zig",
        .old_path = "a/src/app/pages/repository.zig",
        .new_path = "b/src/app/pages/repository.zig",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    },
};

const repository_incoming_viewport_changes_eligibility =
    [_]loaded_diff.FileTextEligibility{ .selectable_utf8, .selectable_utf8 };

const repository_incoming_viewport_changes_tree_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .directory, .name = "app", .path = "src/app", .depth = 1 },
    .{ .kind = .directory, .name = "pages", .path = "src/app/pages", .depth = 2 },
    .{
        .kind = .file,
        .name = "repository.zig",
        .path = "src/app/pages/repository.zig",
        .depth = 3,
        .target = .{ .diff_file = 1 },
    },
    .{
        .kind = .file,
        .name = "app.zig",
        .path = "src/app.zig",
        .depth = 1,
        .target = .{ .diff_file = 0 },
    },
};

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

fn abandonSingleQueuedTask(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) !void {
    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

fn abandonQueuedTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) usize {
    const queued = ctx.takePendingTasksWith();
    for (queued) |task| {
        var abandoned = task.failed(task.ctx, .runtime_abandoned, allocator);
        abandoned.deinitUndelivered(allocator);
    }
    return queued.len;
}

fn deliverStagedBoundaryStatus(
    app: *App,
    ctx: *chasen.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    const identity = app.pages.changes.activation.currentIdentity() orelse
        return error.ExpectedChangesActivation;
    app.pages.changes.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = identity,
        .generation = 6,
        .repo_root = try allocator.dupe(u8, repo_root),
        .result = .{ .loaded = staged_status },
    } } }), ctx);
    staged_status = undefined;
}

fn cloneBoundaryProjectionRequest(
    app: *App,
    allocator: std.mem.Allocator,
) !app_changes_projection.Request {
    const pending = app.pages.changes.changes_projection.pending orelse
        return error.ExpectedBoundaryProjection;
    return app_changes_projection.cloneRequestWithOptions(
        allocator,
        pending.identity,
        pending.id,
        pending.repo_root,
        pending.path_key,
        pending.kind,
        pending.source_kind,
        pending.source_session_revision,
        pending.status_snapshot_revision,
        .{
            .read_epoch = pending.read_epoch,
            .root_identity = pending.root_identity,
            .expected_presentation = pending.expected_presentation,
        },
    );
}

fn expectRetainedStagedOnlyOwner(app: *App, prior_hunks: [*]const diff_parser.Hunk) !void {
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    const ready = switch (app.pages.changes.changes_projection.displayed) {
        .ready => |*ready| ready,
        else => return error.ExpectedRetainedOwner,
    };
    try std.testing.expect(ready.value == .retained_staged_only);
    try std.testing.expect(
        ready.value.retained_staged_only.presentation.projection.file.hunks.ptr == prior_hunks,
    );
    const authority_view = changesNavigationView(app).activeHunkAuthority() orelse
        return error.ExpectedStagedOnlyAuthority;
    try std.testing.expect(authority_view.authority == .staged_only);
}

fn installTestActionCursor(
    app: *App,
    allocator: std.mem.Allocator,
    kind: changes_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repo_session.view().activeIdentity() orelse test_action_root_identity;
    var prepared = try changesNavigation(app).prepareActionCursor(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        kind,
        path_key,
    );
    changesNavigation(app).installActionCursor(allocator, &prepared, action_generation);
}

fn promoteTestActionCursorWithRequirement(
    app: *App,
    action_generation: u64,
    requirement: changes_page.action_cursor.RefreshRequirement,
) !void {
    const owner = app.pages.changes.action_cursor.owner orelse return error.ExpectedActionCursorOwner;
    try std.testing.expect(app.pages.changes.action_cursor.promote(
        action_generation,
        owner.repo_epoch,
        owner.root_identity,
        requirement,
    ));
}

test "Changes staged boundary keeps owner body through real update tail" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const revision_before = app.pages.changes.status_snapshot_revision;

    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);
    try std.testing.expectEqual(revision_before + 1, app.pages.changes.status_snapshot_revision);

    const pending = app.pages.changes.changes_projection.pending orelse
        return error.ExpectedBoundaryProjection;
    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, pending.kind);
    try abandonSingleQueuedTask(&ctx, allocator);

    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);
    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    const current = changesNavigationView(&app).displayedDiffFile() orelse
        return error.ExpectedDisplayedDiff;
    try std.testing.expect(diff_presentation_identity.exactEqual(current, candidate.displayFile()));
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx);
    candidate = undefined;

    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "Changes staged boundary with queued revalidation defers to canonical gate" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    app.pages.changes.activation.queueRevalidation();
    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);

    // The queued full revalidation starts in the same tail and its canonical
    // authority takes over: no navigation-side projection request is issued
    // and the owned combined body stays displayed.
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    const still_combined = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedRetainedCombinedProjection;
    try std.testing.expect(still_combined.displayFile().hunks.ptr == prior_hunks);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    _ = reads;
}
test "Changes staged boundary result lands safely while canonical gate is open" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);
    try std.testing.expect(app.pages.changes.changes_projection.pending != null);
    try abandonSingleQueuedTask(&ctx, allocator);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    // A watch tick cannot open the gate while the boundary read is pending.
    try app.update(.auto_reload_tick, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);

    // A queued full revalidation is not blocked by the pending read: the next
    // update tail starts it while the canonical boundary read is in flight.
    app.pages.changes.activation.queueRevalidation();
    try app.update(.git_action_spinner_tick, &ctx);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle != null);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    _ = reads;

    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx);
    candidate = undefined;

    // The gate's fresh cycle already retired the boundary read: the late
    // result is ignored and the owned combined body stays displayed until the
    // canonical publication commits. Nothing is dropped either way.
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    const held = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedRetainedCombinedProjection;
    try std.testing.expect(held.displayFile().hunks.ptr == prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "Changes watch cycle after staged boundary advances revisions monotonically" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);
    try abandonSingleQueuedTask(&ctx, allocator);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);
    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx);
    candidate = undefined;
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    const boundary_revision = app.pages.changes.status_snapshot_revision;

    // Watch repair cycle: the fully staged worktree reports an empty unstaged
    // source and the same staged-only status. Revisions must only move
    // forward and the owned body must stay visible at every acceptance.
    try app.update(.auto_reload_tick, &ctx);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);

    var watch_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = watch_status },
    } } }), &ctx);
    watch_status = undefined;
    try std.testing.expect(app.pages.changes.status_snapshot_revision >= boundary_revision);
    const status_revision = app.pages.changes.status_snapshot_revision;
    _ = abandonQueuedTasks(&ctx, allocator);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .empty,
    } } }), &ctx);
    _ = abandonQueuedTasks(&ctx, allocator);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .empty,
    } } }), &ctx);

    try std.testing.expect(app.pages.changes.status_snapshot_revision >= status_revision);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);
    try std.testing.expectEqualStrings("a", changesNavigationView(&app).selectedStagePathKey().?);

    // The committed publication resolves the staged-only row through a fresh
    // canonical cached read; deliver it and land on the cached preview.
    const canonical_request = try cloneBoundaryProjectionRequest(&app, allocator);
    try abandonSingleQueuedTask(&ctx, allocator);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = canonical_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(
            allocator,
            app_test_support.diff_cached_projection,
        ) } },
    } } }), &ctx);

    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(app.pages.changes.changes_projection.displayed == .ready);
    try std.testing.expect(app.pages.changes.changes_projection.displayed.ready.value == .cached_diff);
    try std.testing.expect(app.pages.changes.status_snapshot_revision >= status_revision);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "Changes staged boundary result defers during drag and lands afterward" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);
    try abandonSingleQueuedTask(&ctx, allocator);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };

    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx);
    candidate = undefined;

    // Drag holds the display mutation: the combined body stays visible and
    // the result waits in the deferred slot.
    try std.testing.expect(app.pages.changes.deferred_projection_apply != null);
    const held = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedHeldCombinedProjection;
    try std.testing.expect(held.displayFile().hunks.ptr == prior_hunks);

    app.pages.changes.selection_owner = .none;
    try app.update(.git_action_spinner_tick, &ctx);

    try std.testing.expect(app.pages.changes.deferred_projection_apply == null);
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "Changes deferred boundary publication forces frame past skip latch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx, allocator, roots.a);
    try abandonSingleQueuedTask(&ctx, allocator);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx);
    candidate = undefined;
    try std.testing.expect(app.pages.changes.deferred_projection_apply != null);

    // The drag ends on a message whose handler skips its redraw; the tail
    // publishes the deferred owner and must still produce a frame.
    app.pages.changes.selection_owner = .none;
    ctx.resetRedrawSuppressed();
    try app.update(.git_action_spinner_tick, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);

    // An unchanged tail on the same steady state keeps the handler's skip.
    ctx.resetRedrawSuppressed();
    try app.update(.git_action_spinner_tick, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "Changes unchanged tail keeps handler redraw skip" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    ctx.resetRedrawSuppressed();
    try app.update(.git_action_spinner_tick, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "canonical noop commit clearing failure banner forces frame" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, "MM a\x00");
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

    // A previous watch failure left a banner; this cycle finds the same
    // content again (noop commit) and recovers that failure.
    const failure = app_auto_reload.FailureIdentity.init("watch failed");
    app.pages.changes.auto_reload.last_failure = failure;
    app.pages.changes.status.setSourceReloadFailure(
        failure.digest,
        "auto reload failed: {s}",
        .{"boom"},
    );

    // The unchanged source terminal lands on a skip-latched cycle; the tail's
    // noop commit clears the banner and must still produce a frame.
    ctx.resetRedrawSuppressed();
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("test source") },
    } } }), &ctx);

    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(
        std.mem.indexOf(u8, app.pages.changes.status.text(), "auto reload failed") == null,
    );
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
}
test "canonical noop commit without projection kind clears banner and forces frame" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    // Baseline where the gate path resolves no canonical projection kind:
    // the entry is unstaged-only, so the commit takes the kind-less noop
    // branch instead of the displayed-match branch.
    var unstaged_baseline = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(roots.a, &unstaged_baseline);

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx, allocator, roots.a, reads, " M a\x00");
    try finishCanonicalPublicationBranch(&app, &ctx, allocator, roots.a, reads);

    const failure = app_auto_reload.FailureIdentity.init("watch failed");
    app.pages.changes.auto_reload.last_failure = failure;
    app.pages.changes.status.setSourceReloadFailure(
        failure.digest,
        "auto reload failed: {s}",
        .{"boom"},
    );

    ctx.resetRedrawSuppressed();
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("test source") },
    } } }), &ctx);

    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(
        std.mem.indexOf(u8, app.pages.changes.status.text(), "auto reload failed") == null,
    );
    try std.testing.expect(!ctx.redrawWasSuppressed());
}
test "Changes boundary repair revalidation starts in the same update cycle" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .changes,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .pages = .{ .changes = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
        } },
        .terminal_size = .{ .width = 120, .height = 40 },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);

    var source = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff);
    app.pages.changes.load.replaceLoaded(allocator, .{
        .arena = source.takeArena(),
        .loaded = source.loaded,
        .reviewed_files_owned = false,
    });
    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.pages.changes.git_status.replace(roots.a, &status);
    app.pages.changes.status_load.markSuccess();
    acceptTestSource(&app);
    const identity = app.pages.changes.activation.currentIdentity() orelse
        return error.ExpectedChangesActivation;
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = try app_changes_projection.testing.cloneRequest(
            allocator,
            identity,
            1,
            roots.a,
            "a",
            .cached_diff,
            .unstaged,
            app.pages.changes.source_session_revision,
            app.pages.changes.status_snapshot_revision,
        ),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(
            allocator,
            app_test_support.diff_cached_projection,
        ) },
    } };
    const text_ptr =
        app.pages.changes.changes_projection.displayed.ready.value.cached_diff.loaded.text.ptr;

    // Watch is off and no further input arrives after the status terminal:
    // the repair reload must still start inside this same update cycle. The
    // unstage action's cursor restores the path anchor exactly like the real
    // hunk-unstage flow does.
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.pages.changes.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.changes.action_cursor.startMember(8, .status, 6));
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = identity,
        .generation = 6,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = unstaged_status },
    } } }), &ctx);
    unstaged_status = undefined;

    try std.testing.expect(app.pages.changes.changes_projection.displayed == .ready);
    try std.testing.expect(app.pages.changes.changes_projection.displayed.ready.value == .cached_diff);
    try std.testing.expect(
        app.pages.changes.changes_projection.displayed.ready.value.cached_diff.loaded.text.ptr == text_ptr,
    );
    try std.testing.expect(!app.pages.changes.activation.hasQueuedFullRevalidation());
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);
    _ = reads;
}
