//! Root view projection and chrome integration tests.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_mod = @import("../../app.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_test_support = @import("../test_support.zig");
const review_navigation = @import("../pages/review/navigation.zig");
const review_reload = @import("../pages/review/reload.zig");
const review_authority = @import("../diff_surface/authority.zig");
const diff_source = @import("../../diff/source.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_status = @import("../../git/status.zig");
const keymap = @import("keymap");
const theme = @import("theme");

const App = app_mod.App;

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
    if (spec.branch) |branch| try builder.setBranchHead(branch) else builder.setDetached();
    if (spec.upstream) |upstream| try builder.setUpstream(upstream);
    if (spec.ahead) |ahead| builder.setAheadBehind(ahead, spec.behind orelse 0);
    return builder.finish();
}

fn paletteWithOverride(role: theme.Role, color: theme.ColorValue) theme.Palette {
    const FakeConfig = struct {
        role: theme.Role,
        color: theme.ColorValue,
        pub fn get(self: @This(), requested: theme.Role) ?theme.ColorValue {
            if (requested == self.role) return self.color;
            return null;
        }
    };
    return theme.Palette.fromConfig(FakeConfig{ .role = role, .color = color });
}

fn reviewNavigation(app: *App) review_navigation.Controller {
    const size = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.review,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = size.width, .height = size.height },
        .diagnostics = .{ .target = &app.pages.review.status },
    };
}

fn reviewReload(app: *App) review_reload.Controller {
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.review,
        .navigation = reviewNavigation(app),
        .source = app.config.source,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
    };
}

fn syncTestActivation(app: *App) void {
    const source: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        .immutable
    else if (app.pages.review.auto_reload.sourceIsActionable())
        .fresh
    else if (app.pages.review.load.hasPending())
        .pending
    else
        .unavailable;
    _ = app.pages.review.activation.activate(
        app.repo_session.repo_epoch,
        source,
        review_authority.auxiliaryMember(app.pages.review.status_load),
        review_authority.auxiliaryMember(app.pages.review.branch_status_load),
    );
}

fn openAmendConfirmation(app: *App, allocator: std.mem.Allocator, repo_root: []const u8) !void {
    var parts = try app.local_workflow.commit_panel.formatMessageParts(allocator);
    errdefer parts.deinit(allocator);
    const owned_root = try allocator.dupe(u8, repo_root);
    errdefer allocator.free(owned_root);
    app.local_workflow.amend_confirmation = .{
        .repo_root = owned_root,
        .subject = parts.subject,
        .body = parts.body,
    };
    parts = .{ .subject = &.{}, .body = null };
    app.overlay.openAmendCommit();
}

test "amend confirmation chrome follows amend role override" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 30);
    defer ts.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 30 },
        .theme = paletteWithOverride(.amend, .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } }),
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.deinit(std.testing.allocator);

    app.local_workflow.commit_panel.open(.amend);
    app.local_workflow.commit_panel.insert('x');
    try openAmendConfirmation(&app, std.testing.allocator, "/repo");

    try app.view(&ts.surface);

    const content_rect = app_shell_layout.contentRect(ts.surface.size());
    const dialog_rect = ui.Modal.dialogRectFor(content_rect, .{
        .dialog_width = @min(content_rect.width, @as(u16, 72)),
        .dialog_height = @min(content_rect.height, @as(u16, 9)),
    });

    try ts.expectCellText(dialog_rect.col, dialog_rect.row, "╭");
    try std.testing.expect(ts.surface.readCell(dialog_rect.col, dialog_rect.row).?.style.fg.eql(.{ .rgb = .{ 7, 8, 9 } }));
}

test "load empty state shows actionable no changes message" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(82, 18);
    defer ts.deinit();

    const app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 82, .height = 18 },
    };

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No changes");
    try app_test_support.expectSnapshotContains(&ts, "Press r to reload or q to quit.");
}

test "clean empty state shows branch status chrome" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "feature/topic");
    try app_test_support.expectSnapshotContains(&ts, "0 files / 0 hunks");
}

test "clean empty state hides stale branch status chrome" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/other", &bundle);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotNotContains(&ts, "feature/topic");
    try app_test_support.expectSnapshotContains(&ts, "0 files / 0 hunks");
}

test "clean empty state advertises pull only when clean status snapshot is fresh" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(110, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 110, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);
    try app_test_support.expectSnapshotNotContains(&ts, "U to fetch + fast-forward");

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    var ts_ready: chasen.testing.TestSurface = undefined;
    try ts_ready.init(110, 18);
    defer ts_ready.deinit();
    try app.view(&ts_ready.surface);
    try app_test_support.expectSnapshotContains(&ts_ready, "U to fetch + fast-forward");
}

test "clean empty state shows bound fetch key from effective keymap" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .keymap = keymap.Effective.fromConfig(fetch_config),
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "Ctrl+s to fetch");
}

test "clean empty state omits fetch hint when unbound or target is not ready" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);

    try app.view(&ts.surface);
    try app_test_support.expectSnapshotNotContains(&ts, "Ctrl+s to fetch");

    app.pages.review.branch_status.clear();
    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    app.keymap = keymap.Effective.fromConfig(fetch_config);

    var ts_not_ready: chasen.testing.TestSurface = undefined;
    try ts_not_ready.init(120, 18);
    defer ts_not_ready.deinit();
    try app.view(&ts_not_ready.surface);
    try app_test_support.expectSnapshotNotContains(&ts_not_ready, "Ctrl+s to fetch");
}

test "clean empty stdin source does not advertise remote actions" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .config = .{ .source = .stdin },
        .keymap = keymap.Effective.fromConfig(fetch_config),
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "main");
    try app_test_support.expectSnapshotNotContains(&ts, "U to fetch + fast-forward");
    try app_test_support.expectSnapshotNotContains(&ts, "Ctrl+s to fetch");
}

test "load empty state distinguishes missing repository" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    const app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_repository } },
        } },
        .terminal_size = .{ .width = 90, .height = 18 },
    };

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No Git repository");
    try app_test_support.expectSnapshotContains(&ts, "Press q to quit.");
}

test "load failed state shows first error line and retry hint" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 90, .height = 18 },
    };
    defer reviewReload(&app).clearLoadedDiff(app.allocator);
    try app.pages.review.load.replaceFailed(std.testing.allocator, "git diff failed\nsecond line");

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "Could not load diff");
    try app_test_support.expectSnapshotContains(&ts, "git diff failed");
    try app_test_support.expectSnapshotContains(&ts, "Press r to retry or q to quit.");
    try app_test_support.expectSnapshotNotContains(&ts, "second line");
}

test "loaded diff with empty visible filter shows local empty state" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .binary);

    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .review_display = .{ .changed_file_filter = .binary },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
    };
    defer reviewReload(&app).clearLoadedDiff(app.allocator);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No files match current filters");
    try app_test_support.expectSnapshotContains(&ts, "Press F to change filter or r to reload.");
}
