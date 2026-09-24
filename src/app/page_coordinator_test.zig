//! Owner-local tests for page activation and contextual handoff coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_message = @import("message.zig");
const app_state = @import("state.zig");
const app_test_support = @import("test_support.zig");
const diff_surface = @import("diff_surface.zig");
const page = @import("page.zig");
const page_coordinator = @import("page_coordinator.zig");
const page_link = @import("page_link.zig");
const repo_session = @import("repo_session.zig");
const compare_page = @import("pages/compare.zig");
const repository_page = @import("pages/repository.zig");
const history_page = @import("pages/history.zig");
const repository_selection = @import("pages/repository/selection.zig");
const repository_tasks = @import("pages/repository/tasks.zig");
const changes_page = @import("pages/changes.zig");
const changes_content = @import("pages/changes/content.zig");
const changes_navigation = @import("pages/changes/navigation.zig");
const changes_authority = @import("diff_surface/authority.zig");
const context = @import("../context.zig");
const content_fingerprint = @import("../content_fingerprint.zig");
const diff_source = @import("../diff/source.zig");
const diff_view_model = @import("../diff/view_model.zig");
const repo_discovery = @import("../repo/discovery.zig");
const repo_root_capability = @import("../repo/root_capability.zig");
const repository_manifest_model = @import("../repository/manifest.zig");
const repository_source_document = @import("../repository/source.zig");
const repository_tree_model = @import("../repository/tree.zig");

const PageStates = struct {
    changes: changes_page.ChangesPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    history: history_page.HistoryPageState = .{},
    compare: compare_page.ComparePageState = .{},
    config: page.LazyPlaceholder = .{},
};

const TestApp = struct {
    allocator: ?std.mem.Allocator = null,
    active_page: page.Id = .changes,
    repo_session: repo_session.State = .{},
    pages: PageStates = .{},
    config: diff_source.CliConfig = .{},
    status: app_state.StatusMessage = .{},
    overlay: app_state.OverlayState = .{},
    body_size: chasen.Size = .{ .width = 100, .height = 30 },

    const Msg = app_message.Msg;

    fn controller(self: *TestApp) page_coordinator.Controller {
        return .{
            .active_page = &self.active_page,
            .changes = &self.pages.changes,
            .repository = &self.pages.repository,
            .history = &self.pages.history,
            .compare = &self.pages.compare,
            .config_page = &self.pages.config,
            .repo = self.repo_session.view(),
            .source = self.config.source,
            .body_size = self.body_size,
            .status = &self.status,
            .shell_blockers = .{ .help = self.overlay.isHelp() },
        };
    }

    fn update(self: *TestApp, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .switch_page => |target| try app_testing.requestPageSwitch(self, ctx, target),
            else => unreachable,
        }
    }
};

const app_testing = struct {
    fn pageCoordinator(app: *TestApp) page_coordinator.Controller {
        return app.controller();
    }

    fn requestPageSwitch(app: *TestApp, _: *chasen.Ctx(TestApp.Msg), target: page.Id) !void {
        _ = app.controller().requestSwitch(app.allocator orelse std.testing.allocator, target);
    }

    fn prepareChangesRepositoryHandoff(
        app: *TestApp,
        allocator: std.mem.Allocator,
    ) !page_link.RepositoryIncoming {
        return page_coordinator.testing.prepareChangesRepositoryHandoff(app.controller(), allocator);
    }

    fn commitChangesRepositoryHandoff(
        app: *TestApp,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        page_coordinator.testing.commitChangesRepositoryHandoff(app.controller(), allocator, incoming);
    }

    fn commitRepositoryChangesHandoff(app: *TestApp, allocator: std.mem.Allocator) void {
        page_coordinator.testing.commitRepositoryChangesHandoff(app.controller(), allocator);
    }

    fn changesNavigationView(app: *const TestApp) changes_navigation.View {
        return .{
            .page = &app.pages.changes,
            .repo_root = app.repo_session.view().activeRoot(),
            .repo_epoch = app.repo_session.view().epoch(),
            .root_identity = app.repo_session.view().activeIdentity(),
            .source = app.config.source,
            .layout = .{ .width = 100, .height = 30 },
        };
    }

    fn changesContent(app: *const TestApp) changes_content.View {
        return .{
            .page = &app.pages.changes,
            .navigation = changesNavigationView(app),
            .source = app.config.source,
            .repo_root = app.repo_session.view().activeRoot(),
        };
    }
};

test "repository source header page switch cancels header owner without weakening source blocker" {
    var app: TestApp = .{
        .active_page = .repository,
        .pages = .{ .repository = .{ .active = true } },
    };
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.repository.selection_owner = .{ .source_header = repositoryHeaderSelectionForTest() };
    try requestPageSwitchForTest(&app, &ctx, .repository);
    try std.testing.expect(app.pages.repository.activeMouseOwner());
    try std.testing.expect(!app.pages.repository.activeMouseSourceRange());

    app.overlay.openHelp();
    try requestPageSwitchForTest(&app, &ctx, .compare);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(!app.pages.repository.activeMouseOwner());
    try std.testing.expectEqualStrings("close help before switching pages", app.status.text());
    app.overlay.close();

    app.pages.repository.selection_owner = .{ .source_header = repositoryHeaderSelectionForTest() };
    try requestPageSwitchForTest(&app, &ctx, .compare);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expect(!app.pages.repository.activeMouseOwner());

    app.active_page = .repository;
    app.pages.repository.active = true;
    app.pages.repository.selection_owner = .{ .source = repositoryLiveSelectionForTest() };
    app.status.clear();
    try requestPageSwitchForTest(&app, &ctx, .compare);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.activeMouseSourceRange());
    try std.testing.expectEqualStrings("finish Repository mouse selection before switching pages", app.status.text());

    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(
        repositoryLiveSelectionForTest().token,
        0,
    ) };
    app.status.clear();
    try requestPageSwitchForTest(&app, &ctx, .compare);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expect(!app.pages.repository.activeBorrowedSourceRange());
}

test "repository keyboard line selection page exits preserve semantic viewport" {
    const allocator = std.testing.allocator;
    const targets = [_]page.Id{ .compare, .changes };

    inline for (targets) |target| inline for (.{ false, true }) |retain_prior| {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .body_size = .{ .width = 36, .height = 7 },
            .pages = .{ .repository = try repositorySelectionViewportStateForTest(allocator, retain_prior) },
        };
        defer app.pages.repository.deinit(allocator);
        var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

        const viewport_before = app.pages.repository.captureSelectionViewportAnchor() orelse
            return error.ExpectedSelectionViewportAnchor;
        try std.testing.expectEqual(@as(usize, 5), viewport_before.semantic_source);

        try requestPageSwitchForTest(&app, &ctx, target);

        try std.testing.expectEqual(target, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expect(!app.pages.repository.activeBorrowedSourceRange());
        try std.testing.expectEqual(retain_prior, app.pages.repository.retainedSourceSelection() != null);
        if (retain_prior) {
            const viewport_after = app.pages.repository.captureSelectionViewportAnchor() orelse
                return error.ExpectedRetainedViewportAnchor;
            try std.testing.expectEqual(viewport_before.semantic_source, viewport_after.semantic_source);
        } else {
            try std.testing.expectEqual(
                viewport_before.semantic_source,
                app.pages.repository.viewer.source_vertical_scroll,
            );
        }
    };
}

test "page transition blocker leaves page and Changes state unchanged" {
    var app: TestApp = .{};
    app.pages.changes.search.mode = true;
    const activation_id = app_testing.pageCoordinator(&app).activateChanges();
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .switch_page = .compare }, &ctx);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(app.pages.changes.search.mode);
    try std.testing.expectEqual(activation_id, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqualStrings("finish search before switching pages", app.status.text());
    try std.testing.expect(app.pages.compare.activation.state == .inactive);
}

test "History three pane focus does not block direct page switch" {
    var app: TestApp = .{ .active_page = .history };
    app.pages.history.interaction_state.focus = .changed_files;
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .switch_page = .compare }, &ctx);

    try std.testing.expectEqual(page.Id.compare, app.active_page);
}

test "Compare transient owners block transitions" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    app.pages.compare.diff.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "b/src/compare.zig" } },
        .content = .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    try requestPageSwitchForTest(&app, &ctx, .config);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expectEqualStrings("finish Compare mouse selection before switching pages", app.status.text());

    app.pages.compare.diff.selection_owner = .none;
    _ = app.pages.compare.beginBasePicker(allocator).?;
    try requestPageSwitchForTest(&app, &ctx, .config);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expectEqualStrings("close Compare base picker before switching pages", app.status.text());

    app.pages.compare.closeBasePicker(allocator);
    app.pages.compare.diff.search.mode = true;
    try requestPageSwitchForTest(&app, &ctx, .config);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expectEqualStrings("finish Compare search before switching pages", app.status.text());

    app.pages.compare.diff.search.mode = false;
    try requestPageSwitchForTest(&app, &ctx, .config);
    try std.testing.expectEqual(page.Id.config, app.active_page);
}

test "Compare retained selection survives page transitions and clears on repository replacement" {
    const allocator = std.testing.allocator;
    var app: TestApp = .{ .allocator = allocator, .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    app.pages.compare.diff.completed_selection = .{
        .token = .{
            .repo_epoch = app.repo_session.repo_epoch,
            .root_identity = null,
            .source = diff_surface.selection.SourceBasis.init(.{ .range = "compare" }),
            .source_session_revision = 1,
            .display = .{ .loaded = content_fingerprint.Fingerprint.init("diff") },
        },
        .value = .{ .generated_untracked = .{
            .path = try allocator.dupe(u8, "src/main.zig"),
            .range = .{
                .start = .{ .hunk_index = 0, .line_index = 0 },
                .end = .{ .hunk_index = 0, .line_index = 0 },
            },
            .content = .{ .source_side = .{
                .mode = .line,
                .fragment = .{
                    .source_start = 0,
                    .source_end = 1,
                    .text = try allocator.dupe(u8, "selected compare"),
                    .line_count = 1,
                },
            } },
        } },
    };
    app.pages.compare.diff.pinned_selection_basis = .{
        .identity = .{ .target = .{
            .object_format = .sha1,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        } },
    };
    const retained_token = app.pages.compare.diff.completed_selection.?.token;
    const retained_pin = app.pages.compare.diff.pinned_selection_basis.?;
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    try requestPageSwitchForTest(&app, &ctx, .config);
    try std.testing.expectEqual(page.Id.config, app.active_page);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    try requestPageSwitchForTest(&app, &ctx, .compare);
    try std.testing.expectEqual(page.Id.compare, app.active_page);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    // Repository commitment invalidates the complete Compare owner before
    // page coordination reactivates it. The coordinator must not perform a
    // second candidate-only clear that could preserve stale scroll state.
    app.pages.compare.diff.viewer.diff_scroll = 9;
    app.pages.compare.deinit(allocator);
    try std.testing.expectEqual(
        page_coordinator.Intent.compare_refresh,
        app.controller().acceptedRepositoryChange(app.allocator orelse std.testing.allocator),
    );
    try std.testing.expect(app.pages.compare.diff.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.compare.diff.viewer.diff_scroll);
}

test "changes repository transition commit selects exact retained Changes path" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    .selected_node = 0,
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
    app.pages.repository.root_identity = app.repo_session.view().activeIdentity();

    app_testing.commitRepositoryChangesHandoff(&app, allocator);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(!app.pages.repository.active);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.status.text().len);
    try std.testing.expectEqual(@as(u64, 7), app.pages.changes.activation.state.active.repo_epoch);
}

test "changes repository transition commit maps unchanged and unavailable outcomes" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    const cases = [_]struct {
        path: []const u8,
        status: []const u8,
    }{
        .{ .path = "b", .status = "Repository file is already selected in Changes" },
        .{ .path = "missing.zig", .status = "Repository file is not part of the current Changes" },
    };

    for (cases) |case| {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
                .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
            },
            .config = .{ .source = .unstaged },
            .pages = .{
                .changes = .{
                    .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
                    .viewer = .{
                        .selected_target = .{ .diff_file = 1 },
                        .selected_node = 1,
                        .diff_scroll = 9,
                    },
                },
                .repository = .{
                    .active = true,
                    .repo_epoch = 7,
                    .selected_path = case.path,
                },
            },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
        app.pages.repository.root_identity = app.repo_session.view().activeIdentity();

        app_testing.commitRepositoryChangesHandoff(&app, allocator);

        try std.testing.expectEqual(page.Id.changes, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
        try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
        try std.testing.expectEqual(@as(usize, 9), app.pages.changes.viewer.diff_scroll);
        try std.testing.expectEqualStrings(case.status, app.status.text());
    }
}

test "changes repository transition no context dismisses pending and unavailable owners" {
    const allocator = std.testing.allocator;
    const identity: repo_root_capability.Identity = .{ .device = 5, .inode = 8 };
    const cases = [_]enum { pending, unavailable }{ .pending, .unavailable };

    for (cases) |case| {
        var app: TestApp = .{
            .allocator = allocator,
            .active_page = .repository,
            .repo_session = .{
                .repo_epoch = 7,
            },
            .config = .{ .source = .unstaged },
            .pages = .{
                .changes = .{
                    .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                    .viewer = .{
                        .selected_target = .{ .diff_file = 0 },
                        .selected_node = 0,
                        .diff_scroll = 6,
                    },
                },
                .repository = .{
                    .active = true,
                    .repo_epoch = 7,
                    .root_identity = identity,
                    .selected_path = "retained.zig",
                },
            },
        };
        defer app.pages.changes.deinit(allocator);
        defer app.pages.repository.deinit(allocator);
        var incoming = try page_link.RepositoryIncoming.initOwned(
            allocator,
            app.repo_session.repo_epoch,
            identity,
            switch (case) {
                .pending => .{ .location = .{ .path = "pending.zig" } },
                .unavailable => .{ .unavailable = .{
                    .path = "missing.zig",
                    .reason = .path_not_found,
                } },
            },
        );
        app.pages.repository.acceptIncoming(allocator, &incoming);

        app_testing.commitRepositoryChangesHandoff(&app, allocator);

        try std.testing.expectEqual(page.Id.changes, app.active_page);
        try std.testing.expect(!app.pages.repository.active);
        try std.testing.expect(app.pages.repository.incoming == .none);
        try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
        try std.testing.expectEqual(@as(usize, 6), app.pages.changes.viewer.diff_scroll);
        try std.testing.expectEqualStrings("Repository has no resolved file to open in Changes", app.status.text());
    }
}

test "changes repository transition prepare failures leave both pages unchanged" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
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
    acceptTestSource(&app);

    const changes_activation = app.pages.changes.activation.state.active.activation_id;
    const repository_activation = app.pages.repository.activation_id;
    try std.testing.expect(app_testing.changesContent(&app).repositoryTarget() == .location);

    // Discovery path without its committed root capability cannot authorize
    // an owned cross-page path, even when Changes can derive one.
    try std.testing.expectError(
        error.MissingRepositoryIdentity,
        app_testing.prepareChangesRepositoryHandoff(&app, allocator),
    );
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqual(repository_activation, app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .none);

    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        app_testing.prepareChangesRepositoryHandoff(&app, failing.allocator()),
    );
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqual(repository_activation, app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expect(std.meta.eql(
        diff_view_model.BodyCoordinate{ .hunk_header = 0 },
        app.pages.changes.viewer.diff_cursor,
    ));
}

test "changes repository transition commit moves location and replaces old owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
            },
            .repository = .{ .activation_id = 4 },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    acceptTestSource(&app);
    const changes_activation = app.pages.changes.activation.state.active.activation_id;
    const identity = app.repo_session.view().activeIdentity().?;

    var old = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        .{ .location = .{ .path = "old.zig", .line = 9 } },
    );
    app.pages.repository.acceptIncoming(allocator, &old);

    var incoming = try app_testing.prepareChangesRepositoryHandoff(&app, allocator);
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try std.testing.expect(incoming == .location);
    const moved_address = @intFromPtr(incoming.location.path.ptr);
    try std.testing.expectEqualStrings("a", incoming.location.path);

    app_testing.commitChangesRepositoryHandoff(&app, allocator, &incoming);
    incoming_owned = false;
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.next_activation_id);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expectEqual(@as(u64, 5), app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .awaiting_manifest);
    const accepted = app.pages.repository.incoming.manifestIntent().?;
    try std.testing.expectEqual(moved_address, @intFromPtr(accepted.path.ptr));
    try std.testing.expectEqualStrings("a", accepted.path);
    try std.testing.expect(std.meta.eql(
        diff_view_model.BodyCoordinate{ .hunk_header = 0 },
        app.pages.changes.viewer.diff_cursor,
    ));
}

test "changes repository transition direct unavailable uses the same commit boundary" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 3,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    acceptTestSource(&app);

    const changes_activation = app.pages.changes.activation.state.active.activation_id;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        app_testing.prepareChangesRepositoryHandoff(&app, failing.allocator()),
    );
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqual(@as(u64, 0), app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .none);

    var incoming = try app_testing.prepareChangesRepositoryHandoff(&app, allocator);
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try std.testing.expect(incoming == .unavailable);
    const moved_address = @intFromPtr(incoming.unavailable.path.ptr);
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, incoming.unavailable.reason);
    try std.testing.expectEqualStrings("src/deleted.zig", incoming.unavailable.path);

    app_testing.commitChangesRepositoryHandoff(&app, allocator, &incoming);
    incoming_owned = false;
    const unavailable = app.pages.repository.incomingUnavailable().?;
    try std.testing.expectEqual(moved_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, unavailable.reason);
    try std.testing.expectEqualStrings("src/deleted.zig", unavailable.path);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
}

test "changes repository transition no context bypasses identity and retains browser location" {
    const allocator = std.testing.allocator;
    const repository_manifest = @import("../repository/manifest.zig");
    const repository_tree = @import("../repository/tree.zig");
    var document = try repository_manifest.parseOwned(
        allocator,
        try allocator.dupe(u8, "retained.zig\x00other.zig\x00"),
    );
    var document_owned = true;
    errdefer if (document_owned) document.deinit(allocator);
    const tree = try repository_tree.Tree.build(allocator, &document);

    var app: TestApp = .{
        .allocator = allocator,
        .config = .{ .source = .stdin },
        .pages = .{
            .changes = .{ .load = app_test_support.loadState(app_test_support.loadedDiffOne()) },
            .repository = .{
                .activation_id = 4,
                .bundle = .{ .document = document, .tree = tree },
                .load_state = .loaded,
                .viewer = .{ .tree_cursor = 1 },
            },
        },
    };
    // The Repository bundle owns the parsed document from this point. Keep
    // the pre-transfer errdefer only for Tree.build failure; otherwise a later
    // assertion failure would make both cleanup paths release the same bytes.
    document_owned = false;
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    acceptTestSource(&app);
    app.pages.repository.selected_path = app.pages.repository.bundle.?.tree.filePath("retained.zig", .all).?;
    const retained_address = @intFromPtr(app.pages.repository.selected_path.?.ptr);
    const changes_activation = app.pages.changes.activation.state.active.activation_id;

    var old = try page_link.RepositoryIncoming.initOwned(
        allocator,
        9,
        .{ .device = 11, .inode = 13 },
        .{ .unavailable = .{ .path = "old.zig", .reason = .path_not_found } },
    );
    app.pages.repository.acceptIncoming(allocator, &old);

    // No-context claims no repository path authority, so even a fail-first
    // allocator and absent root capability cannot reject its prepare phase.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var incoming = try app_testing.prepareChangesRepositoryHandoff(&app, failing.allocator());
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(failing.allocator());
    try std.testing.expect(incoming == .no_context);
    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqual(@as(u64, 4), app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .unavailable);
    try std.testing.expectEqual(retained_address, @intFromPtr(app.pages.repository.selected_path.?.ptr));
    try std.testing.expectEqual(@as(usize, 1), app.pages.repository.viewer.tree_cursor);

    app_testing.commitChangesRepositoryHandoff(&app, allocator, &incoming);
    incoming_owned = false;
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.changes.activation.state == .inactive);
    try std.testing.expect(app.pages.repository.active);
    try std.testing.expectEqual(@as(u64, 5), app.pages.repository.activation_id);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expectEqual(retained_address, @intFromPtr(app.pages.repository.selected_path.?.ptr));
    try std.testing.expectEqualStrings("retained.zig", app.pages.repository.selected_path.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.repository.viewer.tree_cursor);
}

test "changes repository transition blocker precedes contextual handoff preparation" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var app: TestApp = .{
        .allocator = failing.allocator(),
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
    app.pages.changes.search.mode = true;
    const changes_activation = app.pages.changes.activation.state.active.activation_id;
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    try requestPageSwitchForTest(&app, &ctx, .repository);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expect(app.pages.changes.search.mode);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqualStrings("finish search before switching pages", app.status.text());
    try std.testing.expect(app.pages.repository.incoming == .none);
}

test "changes repository transition prepare failure stays on Changes with bounded diagnostic" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: TestApp = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 7,
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
        .config = .{ .source = .unstaged },
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
            },
            .repository = .{ .activation_id = 4 },
        },
    };
    defer app.pages.changes.deinit(allocator);
    defer app.pages.repository.deinit(allocator);
    defer app.repo_session.repo_state.deinit(allocator);
    acceptTestSource(&app);
    const changes_activation = app.pages.changes.activation.state.active.activation_id;
    var ctx: chasen.Ctx(TestApp.Msg) = .{ ._allocator = allocator };

    try requestPageSwitchForTest(&app, &ctx, .repository);

    try std.testing.expectEqual(page.Id.changes, app.active_page);
    try std.testing.expectEqual(changes_activation, app.pages.changes.activation.state.active.activation_id);
    try std.testing.expectEqual(@as(u64, 4), app.pages.repository.activation_id);
    try std.testing.expect(!app.pages.repository.active);
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expectEqualStrings("could not prepare page navigation", app.status.text());
}

fn requestPageSwitchForTest(
    app: *TestApp,
    ctx: *chasen.Ctx(TestApp.Msg),
    target: page.Id,
) !void {
    try app_testing.requestPageSwitch(app, ctx, target);
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

fn repositorySelectionViewportStateForTest(
    allocator: std.mem.Allocator,
    retain_prior: bool,
) !repository_page.RepositoryPageState {
    const content = "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n";
    const root_identity: repo_root_capability.Identity = .{ .device = 2, .inode = 3 };
    var state: repository_page.RepositoryPageState = .{
        .initialized = true,
        .active = true,
        .activation_id = 4,
        .repo_epoch = 1,
        .root_identity = root_identity,
        .bundle = try repositorySelectionBundleForTest(allocator),
        .load_state = .loaded,
        .freshness = .fresh,
        .manifest_revision = 5,
        .source_revision = 6,
        .viewer = .{
            .focus = .source,
            .source_cursor = 2,
            .source_vertical_scroll = 5,
        },
    };
    errdefer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = try repositorySelectionDocumentForTest(allocator, content);
    const token: repository_selection.RepositoryContentToken = .{
        .repo_epoch = state.repo_epoch,
        .root_identity = root_identity,
        .path = state.displayed_document.?.path,
        .source_fingerprint = content_fingerprint.Fingerprint.init(content),
    };
    if (retain_prior) {
        var prior = repository_selection.DragSelection.init(
            token,
            .line,
            repository_selection.pointFromLine(0),
        );
        prior.update(repository_selection.pointFromLine(6));
        state.completed_selection = try repository_selection.buildCompletedSelection(
            allocator,
            &state.displayed_document.?.value.source,
            prior,
        );
    }
    state.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(token, 2) };
    return state;
}

fn repositorySelectionBundleForTest(allocator: std.mem.Allocator) !repository_tasks.Bundle {
    var document = try repository_manifest_model.parseOwned(allocator, try allocator.dupe(u8, "main.zig\x00"));
    errdefer document.deinit(allocator);
    return .{
        .tree = try repository_tree_model.Tree.build(allocator, &document),
        .document = document,
    };
}

fn repositorySelectionDocumentForTest(
    allocator: std.mem.Allocator,
    content: []const u8,
) !repository_page.DisplayedDocument {
    const bytes = try allocator.dupe(u8, content);
    var document = repository_source_document.Document.initOwned(
        allocator,
        bytes,
        .init(bytes),
    ) catch |err| {
        allocator.free(bytes);
        return err;
    };
    errdefer document.deinit(allocator);
    return .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .authority = .accepted,
        .value = .{ .source = document },
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

fn acceptTestSource(app: *TestApp) void {
    app.pages.changes.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn syncTestActivation(app: *TestApp) void {
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

test "committed context copies accepted bases side paths gaps and exact y bytes" {
    const committed_diff = @import("pages/committed_diff.zig");
    const commit_diff = @import("../git/commit_diff.zig");
    const Controller = @import("pages/committed_diff/coordinator.zig").Controller;
    const selection_action = @import("selection_action.zig");
    const Input = @import("pages/committed_diff/input.zig");
    const app_load = @import("load.zig");
    const diff_selection = @import("../diff/selection.zig");
    const allocator = std.testing.allocator;
    const before = try commit_diff.ObjectId.parse(.sha1, "1" ** 40);
    const after = try commit_diff.ObjectId.parse(.sha1, "2" ** 40);
    const base_tip = try commit_diff.ObjectId.parse(.sha1, "3" ** 40);
    const root_after = try commit_diff.ObjectId.parse(.sha256, "a" ** 64);
    const cases = [_]struct {
        identity: committed_diff.PresentationIdentity,
        page_id: page.Id,
        side: diff_selection.Side,
        character: bool = false,
        root: bool = false,
        lines: []const u8,
        code: []const u8,
    }{
        .{ .identity = .{ .target = .{ .object_format = .sha1, .base_oid = base_tip, .diff_base_oid = before, .head_oid = after } }, .page_id = .compare, .side = .old, .lines = "42-44, 80-81", .code = "first\nold\nthird\nlater\nlast\n" },
        .{ .identity = .{ .diff_basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = after } }, .page_id = .history, .side = .new, .character = true, .lines = "53", .code = "e" },
        .{ .identity = .{ .diff_basis = .{ .object_format = .sha256, .before = .empty_tree, .after = root_after } }, .page_id = .history, .side = .new, .root = true, .lines = "1-2", .code = "\troot  \nsecond\n" },
    };
    const rename_patch =
        "diff --git a/old.zig b/new.zig\n" ++
        "similarity index 70%\nrename from old.zig\nrename to new.zig\n" ++
        "--- a/old.zig\n+++ b/new.zig\n" ++
        "@@ -42,3 +52,3 @@\n first\n-old\n+new\n third\n" ++
        "@@ -80,2 +90,2 @@\n later\n-last\n+tail\n";
    const root_patch = "diff --git a/new.zig b/new.zig\nnew file mode 100644\n--- /dev/null\n+++ b/new.zig\n@@ -0,0 +1,2 @@\n+\troot  \n+second\n";

    for (cases) |case| {
        var state: committed_diff.State = .{};
        defer state.deinit(allocator);
        var activation = diff_surface.authority.Lifecycle.init(if (case.page_id == .compare) .compare else .history);
        _ = activation.activate(7, .immutable, .unavailable, .unavailable);
        var status: app_state.StatusMessage = .{};
        const source: diff_source.SourceMode = .{ .range = @tagName(case.page_id) };
        var bundle: app_load.CommittedDiffBundle = .{ .loaded = try app_load.buildLoadedBundle(allocator, if (case.root) root_patch else rename_patch) };
        defer bundle.deinit();
        try state.replaceDiffWithIdentity(allocator, 7, "/work/repo", null, source, case.identity, true, .none, &bundle);
        state.viewer.display_mode = .side_by_side;
        state.viewer.sidebar_hidden = true;
        state.viewer.focus = .diff;
        var controller: Controller = .{
            .navigation = .{ .diff = &state, .activation = &activation, .status = &status, .current_target = null, .presentation_identity = case.identity, .repo_root = "/work/repo", .repo_epoch = 7, .root_identity = null, .source = source, .layout = .{ .width = 120, .height = 32 } },
            .effect_origin = .{ .page_id = case.page_id, .repo_epoch = 7, .activation_id = 1 },
            .branch_unavailable_message = "unavailable",
        };
        controller.initializeAcceptedBody(allocator, null);
        const drag: diff_selection.DragSelection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "new.zig" } },
            .content = .{ .source_side = .{ .side = case.side, .mode = if (case.character) .character else .line } },
            .origin = if (case.character) .mouse else .keyboard_line,
            .anchor = if (case.character) .{ .hunk_index = 0, .line_index = 2, .leading = 1, .trailing = 2 } else .{ .hunk_index = 0, .line_index = 0 },
            .focus = if (case.character) .{ .hunk_index = 0, .line_index = 2, .leading = 1, .trailing = 2 } else if (case.root) .{ .hunk_index = 0, .line_index = 1 } else .{ .hunk_index = 1, .line_index = 1 },
            .selected_line_count = if (case.character) 1 else if (case.root) 2 else 5,
            .moved = true,
        };
        var msg: Input.Msg = .{ .shared = .{ .selection_action = .copy_context } };
        if (case.character) {
            try std.testing.expect(state.installPinnedPresentationIdentity(case.identity));
            const view = controller.navigation.view();
            var resolver = view.resolver();
            const body = view.bodyView(&resolver);
            const loaded = body.view.activeLoadedDiffConst().?;
            state.completed_selection = try diff_surface.selection.buildParsedFolded(allocator, body.currentContentToken().?, loaded.document.files[0], &.{}, state.selection_layout_revision, drag);
            _ = selection_action.advanceGeneration(&state.selection_generation);
            const raw = body.view.rawDiffPaneGeometry().?;
            const presentation = body.selectionStatusPresentation().?;
            const region = selection_action.statusLayout(.{ .col = 1, .width = raw.width - 1 }, presentation).copy_context.?;
            msg = .{ .shared = .{ .mouse_diff_press = .{ .col = raw.col + region.col, .row = 1 } } };
        } else state.selection_owner = .{ .diff = drag };
        var outcome = try controller.update(allocator, msg);
        defer outcome.deinit(allocator);
        const effect = outcome.clipboard orelse return error.ExpectedContextCopy;
        const plain = try state.completed_selection.?.clipboardText(allocator);
        defer allocator.free(plain);
        try std.testing.expectEqualStrings(case.code, plain);
        const expected_before = if (case.root) commit_diff.canonicalEmptyTreeOid(.sha256) else before;
        const expected_after = if (case.root) root_after else after;
        const expected = try std.fmt.allocPrint(allocator, "Repository: /work/repo\nSurface: {s}\nBefore: {s}{s}\nAfter: {s}\nFile: {s}\nSide: {s}\nLines: {s}\n\nSelected code:\n```\n{s}\n```\n\nQuestion:\n", .{
            if (case.page_id == .compare) "Compare" else "History", if (case.root) "empty-tree " else "", expected_before.slice(), expected_after.slice(), if (case.side == .old) "old.zig" else "new.zig", @tagName(case.side), case.lines, plain,
        });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, effect.text);
        try std.testing.expectEqual(state.selection_generation, effect.selection_generation.?);
        try std.testing.expect(state.selection_owner == .none);

        if (case.page_id == .compare) {
            try std.testing.checkAllAllocationFailures(allocator, struct {
                fn check(owner: std.mem.Allocator, coordinator: Controller) !void {
                    var result = try coordinator.update(owner, .{ .shared = .{ .selection_action = .copy_context } });
                    defer result.deinit(owner);
                    if (result.clipboard == null) {
                        try std.testing.expect(coordinator.navigation.diff.completed_selection != null);
                        try std.testing.expect(coordinator.navigation.diff.pinned_selection_basis != null);
                        return error.OutOfMemory;
                    }
                }
            }.check, .{controller});
            var retry = try controller.update(allocator, .{ .shared = .{ .selection_action = .copy_context } });
            defer retry.deinit(allocator);
            try std.testing.expectEqualStrings(expected, retry.clipboard.?.text);
            controller.navigation.repo_epoch += 1;
        } else {
            var changed = case.identity.diff_basis;
            changed.before = .{ .commit = changed.after };
            controller.navigation.presentation_identity = .{ .diff_basis = changed };
        }
        var stale = try controller.update(allocator, .{ .shared = .{ .selection_action = .copy_context } });
        defer stale.deinit(allocator);
        try std.testing.expect(stale.clipboard == null);
        try std.testing.expect(state.completed_selection == null);
        try std.testing.expect(state.pinned_selection_basis == null);
    }
}
