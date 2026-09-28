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
                .diff_scroll = 2,
                .diff_horizontal_scroll = 999,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 8 },
    };

    const old_scroll = app.pages.changes.viewer.diff_scroll;
    try app.update(.{ .changes = .toggle_line_numbers }, undefined);

    try std.testing.expect(!app.pages.changes.viewer.view_options.line_numbers);
    try std.testing.expectEqual(old_scroll, app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll <= changesNavigationView(&app).visibleBodyTextMaxHorizontalScroll());
}

test "display mode toggle keeps nearby vertical scroll position" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .diff_scroll = 8,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    app.pages.changes.viewer.diff_cursor = changesNavigationView(&app).selectedCoordinateAtOffset(app.pages.changes.viewer.diff_scroll) orelse app.pages.changes.viewer.diff_cursor;

    try app.update(.{ .changes = .toggle_display_mode }, undefined);

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, changesNavigationView(&app).effectiveDisplayMode());
    try std.testing.expect(app.pages.changes.viewer.diff_scroll > 0);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll <= changesNavigationView(&app).selectedFileLineIndex(changesNavigationView(&app).effectiveDisplayMode()).lineCount());
}

test "display mode toggle brings cursor back into view after wheel scroll" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 12,
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
                .diff_scroll = 2,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 15 },
    };
    const old_scroll = app.pages.changes.viewer.diff_scroll;
    app.pages.changes.viewer.diff_cursor = changesNavigationView(&app).selectedCoordinateAtOffset(old_scroll) orelse
        return error.ExpectedCoordinate;

    try app.update(.{ .changes = .mouse_diff_wheel_down }, undefined);

    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(old_scroll + 1, app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(
        app.pages.changes.viewer.diff_scroll,
        changesNavigationView(&app).selectedDiffCursorOffset().?,
    );

    try app.update(.{ .changes = .mouse_diff_wheel_up }, undefined);
    try std.testing.expectEqual(old_scroll, app.pages.changes.viewer.diff_scroll);
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
            .diff_scroll = 4,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.update(.{ .changes = .scroll_diff_up }, &ctx);
    try std.testing.expectEqual(@as(u64, 0), app.pages.changes.display_navigation_input_revision);
    try std.testing.expect(app.pages.changes.pending_display_navigation_restore.?.override == null);

    try app.update(.{ .changes = .scroll_diff_down }, &ctx);

    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.display_navigation_input_revision);
    var restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    var override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.changes.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(changesNavigationView(&app).selectedDiffCursorOffset(), override.diff_cursor_offset);

    try app.update(.{ .changes = .scroll_diff_down }, &ctx);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.changes.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(changesNavigationView(&app).selectedDiffCursorOffset(), override.diff_cursor_offset);

    try app.update(.{ .changes = .document_last }, &ctx);
    try std.testing.expectEqual(@as(u64, 3), app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    const latest_cursor = app.pages.changes.viewer.diff_cursor;
    const latest_cursor_offset = changesNavigationView(&app).selectedDiffCursorOffset();
    const latest_scroll = app.pages.changes.viewer.diff_scroll;
    try std.testing.expectEqual(latest_cursor, override.diff_cursor);
    try std.testing.expectEqual(latest_cursor_offset, override.diff_cursor_offset);
    try std.testing.expectEqual(latest_scroll, override.diff_scroll);

    // A delayed projection completion restores the latest user override, not
    // the acceptance-time cursor and viewport.
    app.pages.changes.viewer.diff_cursor = restore.original.diff_cursor;
    app.pages.changes.viewer.diff_scroll = restore.original.diff_scroll;
    changesReload(&app).restoreDisplayedNavigation(std.testing.allocator, restore.authoritative());
    try std.testing.expectEqual(latest_cursor, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqual(latest_cursor_offset, changesNavigationView(&app).selectedDiffCursorOffset());
    try std.testing.expectEqual(latest_scroll, app.pages.changes.viewer.diff_scroll);

    const revision_before_edge = app.pages.changes.display_navigation_input_revision;
    try app.update(.{ .changes = .document_last }, &ctx);
    try std.testing.expectEqual(revision_before_edge, app.pages.changes.display_navigation_input_revision);
    restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    try std.testing.expectEqual(latest_cursor, restore.override.?.diff_cursor);

    try app.update(.{ .changes = .half_page_up }, &ctx);
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
                .diff_scroll = 1,
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
            .diff_scroll = 4,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.update(.{ .changes = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = 20, .row = diff_render.body_start_row },
    } } }, &ctx);

    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqual(@as(u64, 1), app.pages.changes.display_navigation_input_revision);
    const restore = app.pages.changes.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    const override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(@as(usize, 0), override.diff_scroll);

    // A further timer tick at BOF cannot retarget the cursor or endpoint.
    app.pages.changes.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } };
    const edge_cursor = app.pages.changes.viewer.diff_cursor;
    const edge_owner = app.pages.changes.selection_owner;
    try app.update(.{ .changes = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = 20, .row = diff_render.body_start_row },
    } } }, &ctx);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
    try std.testing.expectEqualDeep(edge_cursor, app.pages.changes.viewer.diff_cursor);
    try std.testing.expectEqualDeep(edge_owner, app.pages.changes.selection_owner);
}
