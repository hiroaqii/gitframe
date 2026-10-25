//! Changes navigation integration tests through the public root update path.

const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../../app.zig");
const app_load = @import("../../load.zig");
const app_test_support = @import("../../test_support.zig");
const app_shell_layout = @import("../../shell_layout.zig");
const app_projection_component = @import("../../projection_component.zig");
const app_changes_projection = @import("../../changes_projection.zig");
const page = @import("../../page.zig");
const changes_page = @import("../changes.zig");
const changes_navigation = @import("navigation.zig");
const changes_reload = @import("reload.zig");
const context = @import("../../../context.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_presentation_identity = @import("../../../diff/presentation_identity.zig");
const diff_render = @import("../../../diff/render.zig");
const git_status = @import("../../../git/status.zig");

const App = app_mod.App;

fn changesNavigationView(app: *const App) changes_navigation.View {
    const size = app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true }).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = size.width, .height = size.height },
    };
}

fn changesNavigation(app: *App) changes_navigation.Controller {
    const view = changesNavigationView(app);
    return .{
        .page = &app.pages.changes,
        .repo_root = view.repo_root,
        .repo_epoch = view.repo_epoch,
        .root_identity = view.root_identity,
        .source = view.source,
        .layout = view.layout,
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

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.pages.changes.search.query.buffer[0..query.len], query);
    app.pages.changes.search.query.len = query.len;
    app.pages.changes.search.query.cursor = query.len;
    @memcpy(app.pages.changes.search.input.buffer[0..query.len], query);
    app.pages.changes.search.input.len = query.len;
    app.pages.changes.search.input.cursor = query.len;
}

fn testCombinedHunkBundle(allocator: std.mem.Allocator) !app_changes_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection);
    errdefer cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_unstaged_projection);
    errdefer unstaged_bundle.deinit();
    var cached_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_cached_projection);
    errdefer cached_authority.deinit();
    var unstaged_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_unstaged_projection);
    errdefer unstaged_authority.deinit();
    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer presentation_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    return .{
        .presentation = .{
            .arena = presentation_arena,
            .projection = projection.presentation,
            .cached_bundle = cached_bundle,
            .unstaged_bundle = unstaged_bundle,
            .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
            .content_token = .init(1),
        },
        .authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached_authority,
            .unstaged_component = unstaged_authority,
            .status_snapshot_revision = 0,
        },
    };
}

test "display mode and search navigation reset horizontal scroll" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .unified,
                .diff_horizontal_scroll = 16,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 8 },
    };

    try app.update(.{ .changes = .toggle_display_mode }, undefined);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_horizontal_scroll);

    app.pages.changes.viewer.diff_horizontal_scroll = 16;
    setDiffSearchQuery(&app, "wide");
    changesNavigation(&app).submitSearch(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_horizontal_scroll);
}

test "line number toggle clamps horizontal scroll without changing vertical scroll" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = .{ .logical = 2 },
                .diff_horizontal_scroll = 999,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 8 },
    };

    const old_scroll = app.pages.changes.viewer.diff_scroll.row();
    try app.update(.{ .changes = .toggle_line_numbers }, undefined);

    try std.testing.expect(!app.pages.changes.viewer.view_options.line_numbers);
    try std.testing.expectEqual(old_scroll, app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll <= changesNavigationView(&app).visibleBodyTextMaxHorizontalScroll());
}

test "display mode toggle keeps nearby vertical scroll position" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .diff_scroll = .{ .logical = 8 },
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    app.pages.changes.viewer.diff_cursor = changesNavigationView(&app).selectedCoordinateAtOffset(app.pages.changes.viewer.diff_scroll.row()) orelse app.pages.changes.viewer.diff_cursor;

    try app.update(.{ .changes = .toggle_display_mode }, undefined);

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, changesNavigationView(&app).effectiveDisplayMode());
    try std.testing.expect(app.pages.changes.viewer.diff_scroll.row() > 0);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll.row() <= changesNavigationView(&app).selectedFileLineIndex(changesNavigationView(&app).effectiveDisplayMode()).lineCount());
}

test "display mode toggle brings cursor back into view after wheel scroll" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = .{ .logical = 12 },
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 9 },
    };

    try std.testing.expect(changesNavigationView(&app).visibleDiffCursorOffset() == null);

    try app.update(.{ .changes = .toggle_display_mode }, undefined);

    try std.testing.expect(changesNavigationView(&app).visibleDiffCursorOffset() != null);
}

test "diff wheel routes through Changes and preserves an edge cursor screen row" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .focus = .sidebar,
                .diff_scroll = .{ .logical = 2 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };
    const old_scroll = app.pages.changes.viewer.diff_scroll.row();
    app.pages.changes.viewer.diff_cursor = changesNavigationView(&app).selectedCoordinateAtOffset(old_scroll) orelse
        return error.ExpectedCoordinate;

    try app.update(.{ .changes = .mouse_diff_wheel_down }, undefined);

    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(old_scroll + 1, app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(
        app.pages.changes.viewer.diff_scroll.row(),
        changesNavigationView(&app).selectedDiffCursorOffset().?,
    );

    try app.update(.{ .changes = .mouse_diff_wheel_up }, undefined);
    try std.testing.expectEqual(old_scroll, app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(old_scroll, changesNavigationView(&app).selectedDiffCursorOffset().?);
}

test "diff mouse drag supports unified fallback and clears on invalidation" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 50, .height = 10 },
    };

    changesNavigation(&app).pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() != null);

    app.terminal_size.width = 140;
    changesNavigation(&app).pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() != null);

    try app.update(.{ .changes = .toggle_display_mode }, undefined);
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);

    app.pages.changes.viewer.display_mode = .side_by_side;
    changesNavigation(&app).pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() != null);
    changesReload(&app).clearLoadedDiff(app.allocator);
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff() == null);
}

test "hidden sidebar keeps tab from changing focus" {
    var app: App = .{
        .pages = .{ .changes = .{
            .viewer = .{
                .focus = .diff,
                .sidebar_hidden = true,
            },
        } },
    };

    try app.update(.{ .changes = .toggle_focus }, undefined);

    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "sidebar navigation keeps status-only target through clamp" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/status-only.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try changesReload(&app).applyStatusProjection(std.testing.allocator, false, .accepted_status);

    const loaded = changesNavigation(&app).activeLoadedDiff().?;
    const status_node = blk: {
        for (loaded.tree.nodes, 0..) |node, index| {
            switch (node.target) {
                .status_entry => break :blk index,
                else => {},
            }
        }
        return error.ExpectedStatusOnlyNode;
    };

    changesNavigation(&app).selectSidebarNode(std.testing.allocator, loaded, status_node);
    changesNavigation(&app).clampSelection(loaded.document.files.len);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(changesNavigationView(&app).selectedFileIndex(loaded) == null);
    try std.testing.expect(changesNavigationView(&app).selectedStatusEntry() != null);
}

test "sidebar navigation moves between status-only nodes" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer changesReload(&app).clearLoadedDiff(app.allocator);
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.changes.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a.zig\x00?? b.zig\x00");
    try app.pages.changes.git_status.replace("/repo", &status_bundle);
    try changesReload(&app).createStatusOnlyLoadedSession(std.testing.allocator, app.pages.changes.git_status.document);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    const first_node = app.pages.changes.viewer.selected_node;

    changesNavigation(&app).selectFileDelta(std.testing.allocator, 1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 1 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(app.pages.changes.viewer.selected_node != first_node);

    changesNavigation(&app).selectFileDelta(std.testing.allocator, -1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expectEqual(first_node, app.pages.changes.viewer.selected_node);
}

test "active diff display uses ready combined projection by identity" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.changes.git_status.deinit();
    defer app.pages.changes.changes_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.changes.git_status.replace("/repo", &mixed_bundle);

    const request = try app_changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.changes.source_session_revision,
        app.pages.changes.status_snapshot_revision,
    );
    app.pages.changes.changes_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    var frame_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer frame_arena.deinit();
    const display = (try changesNavigationView(&app).activeDiffDisplay(frame_arena.allocator(), .unified)) orelse return error.ExpectedActiveDisplay;
    try std.testing.expect(display == .combined_projection);
    try std.testing.expectEqual(@as(usize, 2), display.combined_projection.file.hunks.len);
    const stages = display.hunkStagePresentation();
    try std.testing.expect(stages == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stages.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.unstaged, stages.stateForHunk(1));
    const bundle = changesNavigationView(&app).activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    switch (display.syntaxView()) {
        .combined => |syntax| {
            try std.testing.expect(syntax.origins.ptr == bundle.presentation.projection.presentation_syntax_origins.ptr);
            try std.testing.expect(syntax.cached == &bundle.presentation.cached_bundle.loaded.syntax_spans);
            try std.testing.expect(syntax.unstaged == &bundle.presentation.unstaged_bundle.loaded.syntax_spans);
        },
        .direct => return error.ExpectedCombinedSyntaxView,
    }
}

test "Changes document navigation updates pending restore only on display changes" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = .{ .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 31,
            .status_load = .{ .freshness = .stale_refresh },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer changesReload(&app).clearLoadedDiff(app.allocator);

    changesNavigation(&app).initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(@as(?usize, 0), changesNavigationView(&app).selectedDiffCursorOffset());

    app.pages.changes.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.changes.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = .{ .logical = 4 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };

    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try app.update(.{ .changes = .scroll_diff_up }, &ctx.ctx);
    try std.testing.expectEqual(@as(u64, 0), app.pages.changes.display_navigation_input_revision);
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore.?.override == null);

    try app.update(.{ .changes = .scroll_diff_down }, &ctx.ctx);

    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.display_navigation_input_revision);
    var restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    var override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.changes.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(changesNavigationView(&app).selectedDiffCursorOffset(), override.diff_cursor_offset);

    try app.update(.{ .changes = .scroll_diff_down }, &ctx.ctx);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.changes.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(changesNavigationView(&app).selectedDiffCursorOffset(), override.diff_cursor_offset);

    try app.update(.{ .changes = .document_last }, &ctx.ctx);
    try std.testing.expectEqual(@as(u64, 3), app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    const latest_cursor = app.pages.changes.viewer.diff_cursor;
    const latest_cursor_offset = changesNavigationView(&app).selectedDiffCursorOffset();
    const latest_scroll = app.pages.changes.viewer.diff_scroll.row();
    try std.testing.expectEqual(latest_cursor, override.diff_cursor);
    try std.testing.expectEqual(latest_cursor_offset, override.diff_cursor_offset);
    try std.testing.expectEqual(latest_scroll, override.diff_scroll.row());

    // A delayed projection completion restores the latest user override, not
    // the acceptance-time cursor and viewport.
    app.pages.changes.viewer.diff_cursor = restore.original.diff_cursor;
    app.pages.changes.viewer.diff_scroll = .{ .logical = restore.original.diff_scroll.row() };
    changesReload(&app).restoreDisplayedNavigation(std.testing.allocator, restore.authoritative());
    try std.testing.expectEqual(latest_cursor, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(latest_cursor_offset, changesNavigationView(&app).selectedDiffCursorOffset());
    try std.testing.expectEqual(latest_scroll, app.pages.changes.viewer.diff_scroll.row());

    const revision_before_edge = app.pages.changes.display_navigation_input_revision;
    try app.update(.{ .changes = .document_last }, &ctx.ctx);
    try std.testing.expectEqual(revision_before_edge, app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    try std.testing.expectEqual(latest_cursor, restore.override.?.diff_cursor);

    try app.update(.{ .changes = .half_page_up }, &ctx.ctx);
    try std.testing.expectEqual(revision_before_edge + 1, app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.changes.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(changesNavigationView(&app).selectedDiffCursorOffset(), override.diff_cursor_offset);

    const revision_before_clamp = app.pages.changes.display_navigation_input_revision;
    changesNavigation(&app).clampDiffNavigation();
    try std.testing.expectEqual(revision_before_clamp, app.pages.changes.display_navigation_input_revision);
}

test "Changes drag auto-scroll advances input revision and captures pending restore override" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .changes = .{
            .load = .{ .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 31,
            .status_load = .{ .freshness = .stale_refresh },
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } },
                .diff_scroll = .{ .logical = 1 },
                .sidebar_hidden = true,
                .display_mode = .unified,
            },
            .selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .content = .unified_diff,
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 1 },
                .anchor_cell = .{ .col = 20, .row = diff_render.body_start_row + 1 },
            } },
        } },
        .allocator = allocator,
        .terminal_size = .{ .width = 100, .height = 10 },
        .config = .{ .source = .unstaged },
        .repo_session = .{ .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } } },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    app.pages.changes.pending_display_navigation_restore = .{
        .repo_root = try allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.changes.source_session_revision,
        .original = .{
            .path_key = try allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = .{ .logical = 4 },
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };
    var ctx: chasen.testing.TestCtx(App.Msg) = undefined;
    ctx.init(allocator, std.testing.io);
    defer ctx.deinit();

    try app.update(.{ .changes = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = 20, .row = diff_render.body_start_row },
    } } }, &ctx.ctx);

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.display_navigation_input_revision);
    const restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    const override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(@as(usize, 0), override.diff_scroll.row());

    // A further timer tick at BOF cannot retarget the cursor or endpoint.
    app.pages.changes.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } };
    const edge_cursor = app.pages.changes.viewer.diff_cursor;
    const edge_owner = app.pages.changes.selection_owner;
    try app.update(.{ .changes = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = 20, .row = diff_render.body_start_row },
    } } }, &ctx.ctx);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll.row());
    try std.testing.expectEqualDeep(edge_cursor, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqualDeep(edge_owner, app.pages.changes.selection_owner);
}

test "wrap viewport reaches a tall line tail and keeps search and j k line based" {
    const allocator = std.testing.allocator;
    const patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,4 +1,4 @@\n " ++
        "needle" ++ "x" ** 400 ++ "needle END\n needle next\n third\n fourth\n";
    var bundle = try app_load.buildLoadedBundle(allocator, patch);
    var app: App = .{
        .allocator = allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(bundle.takeArena(), bundle.loaded),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .sidebar_hidden = true, .display_mode = .unified, .view_options = .{ .line_wrap = true }, .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } } },
        } },
        .terminal_size = .{ .width = 40, .height = 14 },
    };
    defer app.pages.changes.deinit(allocator);
    setDiffSearchQuery(&app, "needle");
    changesNavigation(&app).submitSearch(allocator);
    const first_match = app.pages.changes.search.match.?.coordinate;
    try app.update(.{ .changes = .page_diff_down }, undefined);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll == .wrapped);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll.wrapped.anchor.byte > 0);
    try std.testing.expectEqualDeep(first_match, app.pages.changes.viewer.diff_cursor);

    var found_tail = false;
    for (0..12) |_| {
        const nav = changesNavigationView(&app);
        const changes_view = @import("view.zig");
        const ctx = changes_view.Context.init(&app.pages.changes, nav, .default(), .{}, "working tree", .unstaged, null, .{});
        var ts: chasen.testing.TestSurface = undefined;
        try ts.init(nav.diffPaneWidth(), nav.layout.height);
        defer ts.deinit();
        const before = app.pages.changes.viewer.diff_scroll;
        try changes_view.viewDiffPane(ctx, &ts.surface, app.pages.changes.load.state.loaded.loaded);
        try std.testing.expectEqualDeep(before, app.pages.changes.viewer.diff_scroll);
        // The marker follows this source row's first visible continuation.
        try ts.expectCellText(0, diff_render.body_start_row, "»");
        const snapshot = try ts.snapshot(allocator);
        defer allocator.free(snapshot);
        if (std.mem.indexOf(u8, snapshot, "END") != null) {
            found_tail = true;
            break;
        }
        try app.update(.{ .changes = .page_diff_down }, undefined);
    }
    try std.testing.expect(found_tail);
    try app.update(.{ .changes = .scroll_diff_down }, undefined);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.diff_cursor.hunk_line.line_index);
    try app.update(.{ .changes = .scroll_diff_up }, undefined);
    try std.testing.expectEqualDeep(first_match, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 0), changesNavigationView(&app).renderWrapStart());
    changesNavigation(&app).selectSearchMatch(allocator, .forward);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.search.match.?.coordinate.hunk_line.line_index);
    changesNavigation(&app).selectSearchMatch(allocator, .forward);
    try std.testing.expectEqualDeep(first_match, app.pages.changes.search.match.?.coordinate);
}

test "wrap source anchor survives reflow and exact reload and drops on content change" {
    const allocator = std.testing.allocator;
    const patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n-" ++ "old" ** 180 ++ "\n+short\n next\n";
    var bundle = try app_load.buildLoadedBundle(allocator, patch);
    var app: App = .{
        .allocator = allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(bundle.takeArena(), bundle.loaded),
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .sidebar_hidden = true, .display_mode = .side_by_side, .view_options = .{ .line_wrap = true }, .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } } },
        } },
        .terminal_size = .{ .width = 100, .height = 14 },
    };
    defer app.pages.changes.deinit(allocator);
    try app.update(.{ .changes = .page_diff_down }, undefined);
    const saved = app.pages.changes.viewer.diff_scroll.wrapped.anchor;
    try std.testing.expectEqual(@import("../../../diff/selection.zig").Side.old, saved.side.?);
    try std.testing.expect(saved.byte > 0);
    const initial_nav = changesNavigationView(&app);
    const raw = initial_nav.rawDiffPaneGeometry().?;
    const text_col = raw.col + raw.width - initial_nav.diffPaneWidth() + diff_render.cursor_gutter_width + diff_render.lineTextStart(true, .side_by_side);
    changesNavigation(&app).pressDiffMouse(.{ .col = text_col, .row = diff_render.body_start_row });
    changesNavigation(&app).dragDiffMouse(.{ .col = text_col + 4, .row = diff_render.body_start_row });
    var release_adapter = changesNavigation(&app).updateAdapter();
    var released = try release_adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer released.deinit(allocator);
    const selected_bytes = try app.pages.changes.completed_selection.?.clipboardText(allocator);
    defer allocator.free(selected_bytes);
    // All existing reflow routes preserve the actual old-side token, even
    // through narrow unified fallback. Cursor and action coordinates stay source based.
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 14 } }, undefined);
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    try app.update(.{ .terminal_resized = .{ .width = 1, .height = 14 } }, undefined);
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 14 } }, undefined);
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    try app.update(.{ .changes = .toggle_line_numbers }, undefined);
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    try app.update(.{ .changes = .toggle_display_mode }, undefined);
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    try std.testing.expect(changesNavigationView(&app).visibleDiffCursorOffset() != null);
    const retained_bytes = try app.pages.changes.completed_selection.?.clipboardText(allocator);
    defer allocator.free(retained_bytes);
    try std.testing.expectEqualStrings(selected_bytes, retained_bytes);
    const nav = changesNavigationView(&app);
    var resolver = nav.contentResolverAdapter();
    var copied = (try nav.contentView(&resolver).currentLineCopyText(allocator)).?;
    defer copied.deinit(allocator);
    try std.testing.expectEqualStrings("-" ++ "old" ** 180, copied.text());

    var anchor = (try changesReload(&app).view().captureAnchor(allocator)).?;
    defer anchor.deinit(allocator);
    var exact = try app_load.buildLoadedBundle(allocator, patch);
    app.pages.changes.load.clearCurrent(allocator);
    app.pages.changes.load = app_test_support.loadStateWithArena(exact.takeArena(), exact.loaded);
    try std.testing.expect(changesNavigation(&app).restoreReloadAnchor(allocator, changesNavigation(&app).activeLoadedDiff().?, &anchor));
    try std.testing.expectEqualDeep(saved, app.pages.changes.viewer.diff_scroll.wrapped.anchor);
    var changed = try app_load.buildLoadedBundle(allocator, "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n-" ++ "OLD" ** 180 ++ "\n+short\n next\n");
    app.pages.changes.load.clearCurrent(allocator);
    app.pages.changes.load = app_test_support.loadStateWithArena(changed.takeArena(), changed.loaded);
    try std.testing.expect(changesNavigation(&app).restoreReloadAnchor(allocator, changesNavigation(&app).activeLoadedDiff().?, &anchor));
    try std.testing.expectEqual(@as(usize, 0), changesNavigationView(&app).renderWrapStart());
    try app.update(.{ .changes = .toggle_hunk_fold }, undefined);
    try std.testing.expect(app.pages.changes.viewer.diff_cursor == .hunk_header);
    try std.testing.expectEqual(@as(usize, 0), changesNavigationView(&app).renderWrapStart());
    try std.testing.expect(changesNavigationView(&app).visibleDiffCursorOffset() != null);
}
