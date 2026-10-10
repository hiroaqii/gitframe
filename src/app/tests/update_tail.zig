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
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");

const App = app_mod.App;
const OverlayKind = app_state.OverlayKind;
const LoadedDiff = @import("../../loaded_diff.zig").LoadedDiff;
const loaded_diff = @import("../../loaded_diff.zig");
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const CompareLoadFinished = app_load.CompareLoadFinished;
const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const CompareBranchListFinished = app_load.CompareBranchListFinished;
const CompareBranchListLoadTask = app_load.CompareBranchListLoadTask(app_message.Msg);
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

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
        } } }, &ctx.ctx);
        try std.testing.expectEqualStrings("root diagnostic", app.status.text());
        try std.testing.expectEqualStrings("Repository diagnostic", app.pages.repository.status.text());
    }

    try app.update(.{ .repository = .move_down }, &ctx.ctx);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
}

test "git action spinner ticks keep previous ephemeral status" {
    var app: App = .{};
    app.status.set("pushing: {s}", .{"main -> origin/main"});
    _ = beginAcceptedTestAction(&app, .push);
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);

    try app.update(.{ .git_action_spinner_tick = app.action_runtime.view().generation() }, undefined);

    try std.testing.expectEqualStrings("pushing: main -> origin/main", app.status.text());
    try std.testing.expectEqual(@as(u8, 1), action_lifecycle.testing.spinnerTick(&app.action_runtime));
}

test "git action spinner starts when pending action is visible after update" {
    var app: App = .{};
    _ = beginAcceptedTestAction(&app, .push);
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, &tc.ctx);

    try std.testing.expect(action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
}

test "git action spinner self-cancels stale ticks without redraw" {
    var app: App = .{};
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();

    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);

    try std.testing.expect(!action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(u8, 0), action_lifecycle.testing.spinnerTick(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expect(tc.redrawSuppressed());
}

test "grouped result messages keep previous ephemeral status" {
    try std.testing.expect(app_message.keepsEphemeralStatus(.{ .load_finished = undefined }));
    try std.testing.expect(app_message.keepsEphemeralStatus(.{ .action_finished = undefined }));
    try std.testing.expect(app_message.keepsEphemeralStatus(.{ .git_action_spinner_tick = 0 }));
}

test "branch time pickers sample one real-clock snapshot at every non-skipped redraw tail" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    _ = app.pages.compare.beginBasePicker(allocator).?;
    var clock = FakeRealClock.init(1_700_000_059);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, clock.io());
    defer ctx.deinit();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx.ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_059), app.pages.compare.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 1), clock.samples);

    // An unrelated Review source completion crosses the 59s -> 1m boundary
    // through the same common tail instead of a picker-specific handler.
    clock.seconds += 1;
    const refresh = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        refresh.identity,
        refresh.generation,
        'a',
        'b',
    ) } } }, &ctx.ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_060), app.pages.compare.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    // A stale list terminal resolves to skip and therefore does not sample.
    clock.seconds += 1;
    ctx.resetTransient();
    try app.update(.{ .load_finished = .{ .compare = .{ .branch_list = .{
        .identity = refresh.identity,
        .generation = app.pages.compare.base_picker.generation + 1,
        .result = .empty,
    } } } }, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
    try std.testing.expectEqual(@as(?i64, 1_700_000_060), app.pages.compare.base_picker.render_now_unix);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    // Hidden and idle picker states do not consult the wall clock.
    app.active_page = .changes;
    try app.update(.{ .terminal_resized = .{ .width = 100, .height = 24 } }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);
    app.active_page = .compare;
    app.pages.compare.closeBasePicker(allocator);
    try app.update(.{ .terminal_resized = .{ .width = 90, .height = 20 } }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 2), clock.samples);

    var repo_root = "/repo".*;
    var branch = "main".*;
    var oid = "abc123".*;
    var full_ref = "refs/heads/main".*;
    var branches = [_]app_state.BranchSwitchItem{.{
        .full_ref = &full_ref,
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
    app.overlay.openSwitchBranch(.changes);
    app.active_page = .changes;
    clock.seconds += 1;
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx.ctx);
    try std.testing.expectEqual(@as(?i64, 1_700_000_062), app.remote_workflow.branch_switch.render_now_unix);
    try std.testing.expectEqual(@as(usize, 3), clock.samples);
}

test "branch time pickers fail closed for unavailable and zero-resolution real clocks" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    _ = app.pages.compare.beginBasePicker(allocator).?;
    var clock = FakeRealClock.init(1_700_000_000);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, clock.io());
    defer ctx.deinit();

    clock.available = false;
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx.ctx);
    try std.testing.expect(app.pages.compare.base_picker.render_now_unix == null);
    try std.testing.expectEqual(@as(usize, 0), clock.samples);

    clock.available = true;
    clock.resolution_ns = 0;
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx.ctx);
    try std.testing.expect(app.pages.compare.base_picker.render_now_unix == null);
    try std.testing.expectEqual(@as(usize, 0), clock.samples);

    var repo_root = "/repo".*;
    var branch = "main".*;
    var oid = "abc123".*;
    var full_ref = "refs/heads/main".*;
    var branches = [_]app_state.BranchSwitchItem{.{
        .full_ref = &full_ref,
        .name = &branch,
        .oid = &oid,
        .current = true,
        .tip_committer_unix = 1_700_000_000,
    }};
    app.pages.compare.closeBasePicker(allocator);
    app.remote_workflow.branch_switch = .{
        .repo_root = &repo_root,
        .current_branch = &branch,
        .current_oid = &oid,
        .branches = &branches,
    };
    app.overlay.openSwitchBranch(.changes);
    app.active_page = .changes;
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx.ctx);
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
                    .diff_scroll = .{ .logical = 0 },
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
    const source_member: changes_authority.MemberFreshness = .pending;
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
        .compare = .{ .page = &app.pages.compare },
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    return repoSession(app).commitDiscovered(&ctx.ctx, result, active_index, origin);
}

test "Compare wheel redraw completion defers as one bundle during drag and applies afterward" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx.ctx);
    app.pages.compare.diff.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "b/src/compare.zig" } },
        .content = .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    const replacement = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        replacement.identity,
        replacement.generation,
        'd',
        'e',
    ) } } }, &ctx.ctx);

    try std.testing.expect(app.pages.compare.deferred_load_apply != null);
    try std.testing.expectEqualStrings(reviewAppTestOid('b').slice(), app.pages.compare.basis.?.target.head_oid.slice());
    app.pages.compare.diff.selection_owner = .none;

    // This skip-producing spinner message is a synthetic root-tail
    // composition, not a claim that a wheel and deferred publication naturally
    // arrive as one event. The visible deferred owner must win over the
    // provisional skip candidate.
    ctx.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expect(app.pages.compare.deferred_load_apply == null);
    try std.testing.expectEqualStrings(reviewAppTestOid('e').slice(), app.pages.compare.basis.?.target.head_oid.slice());

    ctx.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
}

const CompareInactiveCompletionOrder = enum { completion_before_reentry, completion_after_reentry };

test "Compare inactive completion is accepted only before re-entry starts a newer generation" {
    for ([_]CompareInactiveCompletionOrder{ .completion_before_reentry, .completion_after_reentry }) |order| {
        try expectCompareInactiveCompletionOrder(order);
    }
}

fn expectCompareInactiveCompletionOrder(order: CompareInactiveCompletionOrder) !void {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .compare,
        .config = .{ .source = .{ .patch_file = "change.patch" } },
        .repo_session = .{ .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) } },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    const old = app.pages.compare.beginRefresh().?;
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.{ .switch_page = .repository }, &ctx.ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    // The destination page queues its own reads, separate from Compare's
    // completion/re-entry ordering exercised below.
    ctx.discardPendingTasks();
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    app.status.set("visible page sentinel", .{});

    if (order == .completion_before_reentry) {
        ctx.resetTransient();
        try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
            allocator,
            old.identity,
            old.generation,
            'a',
            'b',
        ) } } }, &ctx.ctx);
        try std.testing.expect(ctx.redrawSuppressed());
        try std.testing.expectEqual(page.Id.repository, app.active_page);
        try std.testing.expectEqualStrings("visible page sentinel", app.status.text());
        try std.testing.expectEqualStrings(reviewAppTestOid('b').slice(), app.pages.compare.basis.?.target.head_oid.slice());
    }

    try app.update(.{ .switch_page = .compare }, &ctx.ctx);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var pending_0 = ctx.takeTask(0).?;
    defer pending_0.deinit();
    var newer_message = try pending_0.fail(error.ConcurrencyUnavailable);
    defer newer_message.deinitUndelivered(ctx.ctx.allocator());
    const newer = newer_message.load_finished.compare.source;
    try std.testing.expect(newer.generation > old.generation);

    ctx.resetTransient();
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        old.identity,
        old.generation,
        'c',
        'd',
    ) } } }, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
    switch (order) {
        .completion_before_reentry => try std.testing.expectEqualStrings(
            reviewAppTestOid('b').slice(),
            app.pages.compare.basis.?.target.head_oid.slice(),
        ),
        .completion_after_reentry => try std.testing.expect(app.pages.compare.basis == null),
    }
}

test "repository commitment resets Compare and refreshes the new physical root" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .compare,
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    _ = app.pages.compare.activate(0);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const initial = app.pages.compare.beginRefresh().?;
    try app.update(.{ .load_finished = .{ .compare = .{ .source = try reviewAppLoadedFinished(
        allocator,
        initial.identity,
        initial.generation,
        'a',
        'b',
    ) } } }, &ctx.ctx);
    try std.testing.expect(app.pages.compare.basis != null);

    const changes_activation = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    const discovery_generation = app.pages.changes.load.beginRepoDiscovery();
    app.pages.changes.load.state = .loading;
    try app.update(.{ .load_finished = .{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(0, changes_activation),
        .generation = discovery_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.b) },
    } } } }, &ctx.ctx);

    try std.testing.expectEqual(@as(u64, 1), app.repo_session.view().epoch());
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(app.pages.compare.basis == null);
    try std.testing.expect(app.pages.compare.base_target == null);
    try std.testing.expect(app.pages.compare.activation.state == .active);
    try std.testing.expectEqual(@as(u64, 1), app.pages.compare.activation.state.active.repo_epoch);
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    var pending_0 = ctx.takeTask(0).?;
    defer pending_0.deinit();
    var task_message = try pending_0.fail(error.ConcurrencyUnavailable);
    defer task_message.deinitUndelivered(ctx.ctx.allocator());
    const task = task_message.load_finished.compare.source;
    try std.testing.expectEqual(app.repo_session.view().epoch(), task.identity.repo_epoch);
}

test "repository activation and manual reload route to page-owned manifest tasks" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .{ .patch_file = "change.patch" } },
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.{ .switch_page = .repository }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.pendingTaskCount());
    var pending_0 = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending_0) |*task| task.deinit();
    var first_message = try pending_0[0].fail(error.ConcurrencyUnavailable);
    defer first_message.deinitUndelivered(ctx.ctx.allocator());
    const first = first_message.repository.manifest_finished;
    try std.testing.expectEqual(page.Id.repository, first.identity.origin);
    try std.testing.expectEqual(app.repo_session.repo_epoch, first.identity.repo_epoch);
    const first_generation = first.generation;
    var first_branch_message = try pending_0[1].fail(error.ConcurrencyUnavailable);
    defer first_branch_message.deinitUndelivered(ctx.ctx.allocator());
    const first_branch = first_branch_message.repository.branch_finished;
    const first_branch_generation = first_branch.generation;
    try std.testing.expectEqual(first.identity, first_branch.identity);

    try app.update(.reload, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.pendingTaskCount());
    var pending_1 = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending_1) |*task| task.deinit();
    var second_message = try pending_1[0].fail(error.ConcurrencyUnavailable);
    defer second_message.deinitUndelivered(ctx.ctx.allocator());
    const second = second_message.repository.manifest_finished;
    try std.testing.expect(second.generation > first_generation);
    try std.testing.expectEqual(second.generation, app.pages.repository.pending_generation.?);
    var second_branch_message = try pending_1[1].fail(error.ConcurrencyUnavailable);
    defer second_branch_message.deinitUndelivered(ctx.ctx.allocator());
    const second_branch = second_branch_message.repository.branch_finished;
    try std.testing.expect(second_branch.generation > first_branch_generation);
    try std.testing.expectEqual(second_branch.generation, app.pages.repository.branch.pending.?.generation);
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.reload, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.pendingTaskCount());
    var pending_0 = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending_0) |*task| task.deinit();
    var old_task_message = try pending_0[0].fail(error.ConcurrencyUnavailable);
    defer old_task_message.deinitUndelivered(ctx.ctx.allocator());
    const old_task = old_task_message.repository.manifest_finished;
    pending_0[1].deinit();
    const old_identity = old_task.identity;
    const old_root_identity = old_task.root_identity;
    const old_generation = old_task.generation;
    try std.testing.expectEqual(page.Id.repository, old_identity.origin);
    try std.testing.expectEqual(app.pages.repository.repo_epoch, old_identity.repo_epoch);
    try std.testing.expectEqual(app.pages.repository.activation_id, old_identity.activation_id);
    try std.testing.expectEqual(app.pages.repository.generation, old_generation);
    try std.testing.expectEqual(old_generation, app.pages.repository.pending_generation.?);
    try std.testing.expect(old_root_identity.eql(root_a_identity));
    try std.testing.expectEqualStrings(roots.a, app.repo_session.view().activeRoot().?);

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
    } } }, &ctx.ctx);

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
    try std.testing.expectEqual(@as(usize, 2), ctx.pendingTaskCount());
    var pending_1 = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending_1) |*task| task.deinit();
    var replacement_task_message = try pending_1[0].fail(error.ConcurrencyUnavailable);
    defer replacement_task_message.deinitUndelivered(ctx.ctx.allocator());
    const replacement_task = replacement_task_message.repository.manifest_finished;
    pending_1[1].deinit();
    try std.testing.expectEqual(replacement_generation, replacement_task.generation);
    try std.testing.expectEqualStrings(roots.b, app.repo_session.view().activeRoot().?);
    try std.testing.expect(replacement_task.root_identity.eql(root_b_identity));
    try std.testing.expectEqual(@as(usize, 0), app.pages.repository.status.text().len);
    // The stale completion is a skip candidate, but the same root tail arms
    // the visible replacement manifest lifecycle and therefore needs a frame.
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
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
        var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
        ctx.init(failing.allocator(), std.testing.io);
        defer ctx.deinit();

        try std.testing.expectError(error.OutOfMemory, app.update(.{ .switch_page = .repository }, &ctx.ctx));

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
        try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
        try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
    }
}

test "wheel redraw error terminal does not suppress the root frame" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .active_page = .history,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .terminal_size = .{ .width = 80, .height = 8 },
    };
    defer app.pages.history.deinit(allocator);
    defer app.repo_session.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    app.pages.history.activate(
        allocator,
        app.repo_session.repo_epoch,
        app.repo_session.view().activeIdentity(),
    );
    app.pages.history.needs_initial = false;
    app.pages.history.load_state = .loaded;
    app.pages.history.current_view = .diff;
    app.pages.history.diff.load = app_test_support.loadState(app_test_support.loadedDiffOne());
    app.pages.history.diff.viewer = .{ .focus = .diff, .sidebar_hidden = true, .display_mode = .unified };

    const wheel_down: App.Msg = .{ .history = .{ .common = .{ .shared = .mouse_diff_wheel_down } } };
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
    var reached_noop = false;
    for (0..128) |_| {
        ctx.resetTransient();
        try app.update(wheel_down, &ctx.ctx);
        if (ctx.redrawSuppressed()) {
            reached_noop = true;
            break;
        }
    }
    try std.testing.expect(reached_noop);

    app.pages.history.needs_initial = true;
    app.pages.history.load_state = .loading;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    failing_ctx.init(failing.allocator(), std.testing.io);
    defer failing_ctx.deinit();
    try std.testing.expectError(error.OutOfMemory, app.update(wheel_down, &failing_ctx.ctx));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!failing_ctx.redrawSuppressed());
}

test "Repository tree wheel redraw preserves meaningful owner path and incoming transitions" {
    const allocator = std.testing.allocator;
    var app = try repositoryWheelAppForTest(
        allocator,
        "a.zig\x00b.zig\x00",
        "zero\none\ntwo\nthree\nfour\nfive\n",
    );
    defer app.pages.repository.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const wheel_up: App.Msg = .{ .repository = .wheel_up };
    const wheel_down: App.Msg = .{ .repository = .wheel_down };

    // Ownerless tree input first changes focus/cursor, then becomes a complete
    // top-edge no-op; the opposite direction remains immediately meaningful.
    app.pages.repository.viewer.focus = .source;
    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqual(@as(usize, 0), app.pages.repository.viewer.tree_cursor);
    try std.testing.expectEqual(@import("../pages/repository/model.zig").Focus.tree, app.pages.repository.viewer.focus);

    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqualStrings("a.zig", app.pages.repository.selected_path.?);

    // This is the lifetime-sensitive sequence: the first wheel clears a
    // keyboard owner, selects another manifest path, and destroys the old
    // displayed document. Assertions intentionally read no old borrow.
    app.pages.repository.viewer.focus = .source;
    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(
        repositoryContentTokenForTest(&app.pages.repository),
        1,
    ) };
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expect(app.pages.repository.selection_owner == .none);
    try std.testing.expectEqualStrings("b.zig", app.pages.repository.selected_path.?);
    try std.testing.expect(app.pages.repository.displayed_document == null);

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqualStrings("a.zig", app.pages.repository.selected_path.?);

    // At the bottom edge, dismissing an incoming destination is itself the
    // only meaningful first transition; the following event is a true no-op.
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.pages.repository.repo_epoch,
        app.pages.repository.root_identity.?,
        .{ .location = .{ .path = "incoming.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expect(app.pages.repository.incoming == .none);

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());

    // A provisional edge skip cannot hide a Repository tail diagnostic.
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    app.pages.repository.needs_revalidation = true;
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqual(repository_page.LoadState.no_repository, app.pages.repository.load_state);
    app.pages.repository.status.clear();
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
}

test "Repository source wheel redraw preserves semantic and pointer owners" {
    const allocator = std.testing.allocator;
    var app = try repositoryWheelAppForTest(
        allocator,
        "main.zig\x00",
        "row 00\nrow 01\nrow 02\nrow 03\nrow 04\nrow 05\nrow 06\nrow 07\nrow 08\nrow 09\nrow 10\nrow 11\n",
    );
    defer app.pages.repository.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const body_size = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize();
    const source = switch (app.pages.repository.displayed_document.?.value) {
        .source => |*document| document,
        .inert => return error.ExpectedRepositorySource,
    };
    app.pages.repository.viewer.source_cursor = source.rowCount() - 1;
    app.pages.repository.viewer.source_vertical_scroll.line = std.math.maxInt(usize);
    app.pages.repository.clampForBodySize(body_size);
    const bottom = app.pages.repository.viewer.source_vertical_scroll.line;
    try std.testing.expect(bottom > 0);

    const wheel_down: App.Msg = .{ .repository = .mouse_source_wheel_down };
    const wheel_up: App.Msg = .{ .repository = .mouse_source_wheel_up };

    // With the viewport already at the bottom, the first event still advances
    // the semantic cursor and focus. Only the following edge event is inert.
    app.pages.repository.viewer.focus = .tree;
    app.pages.repository.viewer.source_cursor = source.rowCount() - 2;
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqual(source.rowCount() - 1, app.pages.repository.viewer.source_cursor);

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());

    // A keyboard-line owner keeps its token, endpoint, and semantic cursor;
    // pointer wheel changes only the source viewport.
    const token = repositoryContentTokenForTest(&app.pages.repository);
    app.pages.repository.viewer.focus = .source;
    app.pages.repository.viewer.source_cursor = 3;
    app.pages.repository.viewer.source_vertical_scroll.line = bottom - 1;
    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(token, 3) };
    const endpoint_before = app.pages.repository.selection_owner.activeKeyboardLineSelection().?.focus;

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqual(bottom, app.pages.repository.viewer.source_vertical_scroll.line);
    try std.testing.expectEqual(@as(usize, 3), app.pages.repository.viewer.source_cursor);
    try std.testing.expect(std.meta.eql(endpoint_before, app.pages.repository.selection_owner.activeKeyboardLineSelection().?.focus));
    try std.testing.expect(app.pages.repository.selection_owner.activeKeyboardLineSelection().?.token.eql(token));

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.pages.repository.repo_epoch,
        app.pages.repository.root_identity.?,
        .{ .location = .{ .path = "incoming.zig" } },
    );
    app.pages.repository.acceptIncoming(allocator, &incoming);
    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expect(app.pages.repository.activeKeyboardLineSelection());

    ctx.resetTransient();
    try app.update(wheel_down, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());

    ctx.resetTransient();
    try app.update(wheel_up, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
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
        var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
        ctx.init(allocator, std.testing.io);
        defer ctx.deinit();
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
                try app.update(msg, &ctx.ctx);
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
                } } }, &ctx.ctx);
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
                    .diff_scroll = .{ .logical = 5 },
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.{ .switch_page = .changes }, &ctx.ctx);

    try std.testing.expectEqualStrings("Repository file is not part of the current Changes", app.status.text());
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 3), ctx.pendingTaskCount());
    var pending_0 = [_]chasen.testing.TestTask(App.Msg){ ctx.takeTask(0).?, ctx.takeTask(0).?, ctx.takeTask(0).? };
    defer for (&pending_0) |*task| task.deinit();
    var diff_task_message = try pending_0[2].fail(error.ConcurrencyUnavailable);
    defer diff_task_message.deinitUndelivered(ctx.ctx.allocator());
    const diff_task = diff_task_message.load_finished.changes.source;
    var status_task_message = try pending_0[0].fail(error.ConcurrencyUnavailable);
    defer status_task_message.deinitUndelivered(ctx.ctx.allocator());
    const status_task = status_task_message.load_finished.changes.status;
    pending_0[1].deinit();
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
    } } } }, &ctx.ctx);
    try app.update(.{ .load_finished = .{ .changes = .{ .status = .{
        .identity = status_task.identity,
        .read_epoch = status_task.read_epoch,
        .generation = status_task.generation,
        .background_cycle_id = status_task.background_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .empty,
    } } } }, &ctx.ctx);

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
                },
                .head_display = head_display,
                .target = .{
                    .object_format = .sha1,
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

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?git_branch_status.Upstream = null,
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

fn repositoryWheelAppForTest(
    allocator: std.mem.Allocator,
    paths: []const u8,
    content: []const u8,
) !App {
    const repository_manifest = @import("../../repository/manifest.zig");
    const repository_tree = @import("../../repository/tree.zig");
    const source_document = @import("../../repository/source.zig");

    var manifest = try repository_manifest.parseOwned(allocator, try allocator.dupe(u8, paths));
    var manifest_owned = true;
    errdefer if (manifest_owned) manifest.deinit(allocator);
    const tree = try repository_tree.Tree.build(allocator, &manifest);
    var repository: repository_page.RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = .{ .device = 5, .inode = 8 },
        .bundle = .{
            .document = manifest,
            .tree = tree,
        },
        .load_state = .loaded,
        .freshness = .fresh,
        .manifest_revision = 6,
        .source_revision = 7,
        .viewer = .{ .tree_cursor = 1 },
    };
    manifest_owned = false;
    errdefer repository.deinit(allocator);
    repository.selected_path = repository.bundle.?.tree.firstFilePath();

    const source_bytes = try allocator.dupe(u8, content);
    var source = try source_document.Document.initOwned(
        allocator,
        source_bytes,
        .init(source_bytes),
    );
    errdefer source.deinit(allocator);
    repository.displayed_document = .{
        .path = try allocator.dupe(u8, repository.selected_path.?),
        .manifest_revision = repository.manifest_revision,
        .source_revision = repository.source_revision,
        .authority = .accepted,
        .value = .{ .source = source },
    };

    return .{
        .allocator = allocator,
        .active_page = .repository,
        .terminal_size = .{ .width = 80, .height = 10 },
        .pages = .{ .repository = repository },
    };
}

fn repositoryContentTokenForTest(
    state: *const repository_page.RepositoryPageState,
) repository_selection.RepositoryContentToken {
    const source = switch (state.displayed_document.?.value) {
        .source => |document| document,
        .inert => unreachable,
    };
    return .{
        .repo_epoch = state.repo_epoch,
        .root_identity = state.root_identity.?,
        .path = state.selected_path.?,
        .source_fingerprint = source.fingerprint,
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

const repository_incoming_viewport_changes_files = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/src/app.zig b/src/app.zig",
        .old_path = "src/app.zig",
        .new_path = "src/app.zig",
        .metadata = &.{"index 1..2 100644"},
        .hunks = &.{},
    },
    .{
        .header = "diff --git a/src/app/pages/repository.zig b/src/app/pages/repository.zig",
        .old_path = "src/app/pages/repository.zig",
        .new_path = "src/app/pages/repository.zig",
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

fn discardSingleQueuedTask(ctx: *chasen.testing.TestCtx(App.Msg)) !void {
    try std.testing.expectEqual(@as(usize, 1), ctx.pendingTaskCount());
    ctx.discardPendingTasks();
}

fn discardQueuedTasks(ctx: *chasen.testing.TestCtx(App.Msg)) usize {
    const count = ctx.pendingTaskCount();
    ctx.discardPendingTasks();
    return count;
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;
    const revision_before = app.pages.changes.status_snapshot_revision;

    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);
    try std.testing.expectEqual(revision_before + 1, app.pages.changes.status_snapshot_revision);

    const pending = app.pages.changes.changes_projection.pending orelse
        return error.ExpectedBoundaryProjection;
    try std.testing.expectEqual(app_changes_projection.Kind.cached_diff, pending.kind);
    try discardSingleQueuedTask(&ctx);

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
    } } }), &ctx.ctx);
    candidate = undefined;

    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "Changes staged boundary with queued revalidation defers to canonical gate" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    app.pages.changes.activation.queueRevalidation();
    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);

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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);
    try std.testing.expect(app.pages.changes.changes_projection.pending != null);
    try discardSingleQueuedTask(&ctx);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    // A watch tick cannot open the gate while the boundary read is pending.
    try app.update(.auto_reload_tick, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());

    // A queued full revalidation is not blocked by the pending read: the next
    // update tail starts it while the canonical boundary read is in flight.
    app.pages.changes.activation.queueRevalidation();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
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
    } } }), &ctx.ctx);
    candidate = undefined;

    // The gate's fresh cycle already retired the boundary read: the late
    // result is ignored and the owned combined body stays displayed until the
    // canonical publication commits. Nothing is dropped either way.
    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    const held = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedRetainedCombinedProjection;
    try std.testing.expect(held.displayFile().hunks.ptr == prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "Changes watch cycle after staged boundary advances revisions monotonically" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);
    try discardSingleQueuedTask(&ctx);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);
    var candidate = try canonicalPublicationStagedOnlyReuseCandidate(
        allocator,
        app.pages.changes.status_snapshot_revision,
    );
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = result_request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    } } }), &ctx.ctx);
    candidate = undefined;
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    const boundary_revision = app.pages.changes.status_snapshot_revision;

    // Watch repair cycle: the fully staged worktree reports an empty unstaged
    // source and the same staged-only status. Revisions must only move
    // forward and the owned body must stay visible at every acceptance.
    try app.update(.auto_reload_tick, &ctx.ctx);
    const reads = try takeCanonicalPublicationReads(&ctx, allocator);

    var watch_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = reads.status_identity,
        .read_epoch = reads.status_read_epoch,
        .generation = reads.status_generation,
        .background_cycle_id = reads.status_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .{ .loaded = watch_status },
    } } }), &ctx.ctx);
    watch_status = undefined;
    try std.testing.expect(app.pages.changes.status_snapshot_revision >= boundary_revision);
    const status_revision = app.pages.changes.status_snapshot_revision;
    _ = discardQueuedTasks(&ctx);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = reads.branch_identity,
        .read_epoch = reads.branch_read_epoch,
        .generation = reads.branch_generation,
        .background_cycle_id = reads.branch_cycle_id,
        .repo_root = try allocator.dupe(u8, roots.a),
        .result = .empty,
    } } }), &ctx.ctx);
    _ = discardQueuedTasks(&ctx);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);

    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .empty,
    } } }), &ctx.ctx);

    try std.testing.expect(app.pages.changes.status_snapshot_revision >= status_revision);
    try std.testing.expect(changesNavigationView(&app).displayedChangesBody() != .none);
    try std.testing.expectEqualStrings("a", changesNavigationView(&app).selectedStagePathKey().?);

    // The committed publication resolves the staged-only row through a fresh
    // canonical cached read; deliver it and land on the cached preview.
    const canonical_request = try cloneBoundaryProjectionRequest(&app, allocator);
    try discardSingleQueuedTask(&ctx);
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = canonical_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(
            allocator,
            app_test_support.diff_cached_projection,
        ) } },
    } } }), &ctx.ctx);

    try std.testing.expect(app.pages.changes.changes_projection.pending == null);
    try std.testing.expect(app.pages.changes.changes_projection.displayed == .ready);
    try std.testing.expect(app.pages.changes.changes_projection.displayed.ready.value == .cached_diff);
    try std.testing.expect(app.pages.changes.status_snapshot_revision >= status_revision);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "Changes staged boundary result defers during drag and lands afterward" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);
    try discardSingleQueuedTask(&ctx);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
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
    } } }), &ctx.ctx);
    candidate = undefined;

    // Drag holds the display mutation: the combined body stays visible and
    // the result waits in the deferred slot.
    try std.testing.expect(app.pages.changes.deferred_projection_apply != null);
    const held = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedHeldCombinedProjection;
    try std.testing.expect(held.displayFile().hunks.ptr == prior_hunks);

    app.pages.changes.selection_owner = .none;
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);

    try std.testing.expect(app.pages.changes.deferred_projection_apply == null);
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "Changes deferred boundary publication forces frame past skip latch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const prior = changesNavigationView(&app).activeCombinedProjection() orelse
        return error.ExpectedCombinedProjection;
    const prior_hunks = prior.displayFile().hunks.ptr;

    try deliverStagedBoundaryStatus(&app, &ctx.ctx, allocator, roots.a);
    try discardSingleQueuedTask(&ctx);
    const result_request = try cloneBoundaryProjectionRequest(&app, allocator);

    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
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
    } } }), &ctx.ctx);
    candidate = undefined;
    try std.testing.expect(app.pages.changes.deferred_projection_apply != null);

    // The drag ends on a message whose handler skips its redraw; the tail
    // publishes the deferred owner and must still produce a frame.
    app.pages.changes.selection_owner = .none;
    ctx.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expect(!ctx.redrawSuppressed());
    try expectRetainedStagedOnlyOwner(&app, prior_hunks);

    // An unchanged tail on the same steady state keeps the handler's skip.
    ctx.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "Changes unchanged tail keeps handler redraw skip" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    ctx.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &ctx.ctx);
    try std.testing.expect(ctx.redrawSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "canonical noop commit clearing failure banner forces frame" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, "MM a\x00");
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

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
    ctx.resetTransient();
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("test source") },
    } } }), &ctx.ctx);

    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(
        std.mem.indexOf(u8, app.pages.changes.status.text(), "auto reload failed") == null,
    );
    try std.testing.expect(!ctx.redrawSuppressed());
    try std.testing.expectEqual(@as(usize, 0), ctx.pendingTaskCount());
}
test "canonical noop commit without projection kind clears banner and forces frame" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try canonicalPublicationTestApp(allocator, roots.a);
    defer app.pages.changes.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    // Baseline where the gate path resolves no canonical projection kind:
    // the entry is unstaged-only, so the commit takes the kind-less noop
    // branch instead of the displayed-match branch.
    var unstaged_baseline = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try app.pages.changes.git_status.replace(roots.a, &unstaged_baseline);

    const reads = try startCanonicalPublicationWatch(&app, &ctx, allocator);
    try finishCanonicalPublicationStatus(&app, &ctx.ctx, allocator, roots.a, reads, " M a\x00");
    try finishCanonicalPublicationBranch(&app, &ctx.ctx, allocator, roots.a, reads);

    const failure = app_auto_reload.FailureIdentity.init("watch failed");
    app.pages.changes.auto_reload.last_failure = failure;
    app.pages.changes.status.setSourceReloadFailure(
        failure.digest,
        "auto reload failed: {s}",
        .{"boom"},
    );

    ctx.resetTransient();
    try app.update(App.Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = reads.source_identity,
        .read_epoch = reads.source_read_epoch,
        .generation = reads.source_generation,
        .background_cycle_id = reads.source_cycle_id,
        .result = .{ .unchanged = content_fingerprint.Fingerprint.init("test source") },
    } } }), &ctx.ctx);

    try std.testing.expect(app.pages.changes.canonical_publication == null);
    try std.testing.expect(
        std.mem.indexOf(u8, app.pages.changes.status.text(), "auto reload failed") == null,
    );
    try std.testing.expect(!ctx.redrawSuppressed());
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
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();
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
    } } }), &ctx.ctx);
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
