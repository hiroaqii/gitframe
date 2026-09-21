//! Root-shell input and lifecycle integration tests.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const app_mod = @import("../../app.zig");
const app_test_support = @import("../test_support.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const selection_action = @import("../selection_action.zig");
const app_view = @import("../view.zig");
const action_lifecycle = @import("../workflow/action_lifecycle.zig");
const page = @import("../page.zig");
const changes_page = @import("../pages/changes.zig");
const changes_navigation = @import("../pages/changes/navigation.zig");
const changes_reload = @import("../pages/changes/reload.zig");
const compare_page = @import("../pages/compare.zig");
const committed_diff_navigation = @import("../pages/committed_diff/navigation.zig");
const repository_selection = @import("../pages/repository/selection.zig");
const diff_surface = @import("../diff_surface.zig");
const changes_authority = @import("../diff_surface/authority.zig");
const context = @import("../../context.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_render = @import("../../diff/render.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_status = @import("../../git/status.zig");
const git_history = @import("../../git/history.zig");
const repo_discovery = @import("../../repo/discovery.zig");

const App = app_mod.App;
const OverlayKind = app_state.OverlayKind;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const sidebar_header_rows: u16 = @import("../pages/changes/layout.zig").sidebar_header_rows;

fn shellLayout(app: *const App) app_shell_layout.Layout {
    return app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
}

fn layoutSize(app: *const App) chasen.Size {
    return app_shell_layout.contentSize(app.terminal_size);
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return @import("../pages/changes/layout.zig").sidebarWidth(total_width, preferred_width);
}

fn terminalBodyHeight(terminal_height: u16) u16 {
    return app_shell_layout.bodyHeight(terminal_height);
}

fn historyRecordForRootTest(
    allocator: std.mem.Allocator,
    oid: git_history.ObjectId,
    parent_count: u16,
    first_parent: git_history.FirstParent,
    subject: []const u8,
) !git_history.Record {
    const author = try allocator.dupe(u8, "Test");
    errdefer allocator.free(author);
    const decorations = try allocator.dupe(u8, "");
    errdefer allocator.free(decorations);
    const owned_subject = try allocator.dupe(u8, subject);
    return .{
        .oid = oid,
        .parent_count = parent_count,
        .first_parent = first_parent,
        .author = author,
        .committer_unix = 0,
        .decorations = decorations,
        .subject = owned_subject,
    };
}

fn footerStatusPress(app: *const App) ?App.Msg {
    const layout = shellLayout(app);
    if (layout.footer.height == 0) return null;
    for (0..layout.footer.width) |offset| {
        const msg = app.handleEvent(app_test_support.mouseEvent(
            @as(i16, @intCast(@as(usize, layout.footer.col) + offset)),
            @as(i16, @intCast(layout.footer.row)),
            .left,
        )) orelse continue;
        switch (msg) {
            .copy_footer_status => return msg,
            else => {},
        }
    }
    return null;
}

fn changesNavigation(app: *App) changes_navigation.Controller {
    const size = shellLayout(app).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.changes,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = app.config.source,
        .layout = .{ .width = size.width, .height = size.height },
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
    return app.pages.changes.activation.activate(app.repo_session.view().epoch(), source_member, auxiliary, auxiliary);
}

fn compareNavigation(app: *App) committed_diff_navigation.Controller {
    const size = shellLayout(app).bodySize();
    const repo = app.repo_session.view();
    return .{
        .diff = &app.pages.compare.diff,
        .activation = &app.pages.compare.activation,
        .status = &app.pages.compare.status,
        .current_target = app.pages.compare.currentTarget(),
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .source = compare_page.selection_source,
        .layout = .{ .width = size.width, .height = size.height },
        .live_drag_deferred_source = app.pages.compare.deferred_load_apply != null,
    };
}

fn installRootCompareSelection(app: *App, allocator: std.mem.Allocator) !void {
    app.pages.compare.diff.clearRetainedSelection(allocator);
    const loaded = switch (app.pages.compare.diff.load.state) {
        .loaded => |*session| &session.loaded,
        else => return error.ExpectedLoadedCompare,
    };
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    };
    app.pages.compare.diff.completed_selection = try diff_surface.selection.buildParsedFolded(allocator, .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = diff_surface.selection.SourceBasis.init(compare_page.selection_source),
        .source_session_revision = app.pages.compare.diff.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
    }, loaded.document.files[0], loaded.foldedHunksForFile(0), app.pages.compare.diff.selection_layout_revision, selection);
    _ = selection_action.advanceGeneration(&app.pages.compare.diff.selection_generation);
    if (!app.pages.compare.diff.installPinnedSelectionBasis(app.pages.compare.currentTarget())) return error.ExpectedCompareSelectionPin;
}

fn selectionActionMouseEvent(
    app: *App,
    raw: diff_surface.RawDiffPaneGeometry,
    presentation: diff_surface.selection_action.StatusPresentation,
    target: selection_action.StatusAction,
) !chasen.Event {
    const action_layout = diff_surface.selection_action.statusLayout(
        .{ .col = 1, .width = raw.width - 1 },
        presentation,
    );
    const region = switch (target) {
        .copy => action_layout.copy orelse return error.ExpectedCopyAction,
        .copy_hunk => action_layout.copy_hunk orelse return error.ExpectedCopyHunkAction,
        .clear => action_layout.clear orelse return error.ExpectedClearAction,
    };
    const layout = shellLayout(app);
    return app_test_support.mouseEvent(
        layout.body.col + raw.col + region.col,
        layout.body.row + 1,
        .left,
    );
}

fn changesActionMouseEvent(app: *App, target: selection_action.StatusAction) !chasen.Event {
    const view = changesNavigation(app).view();
    return selectionActionMouseEvent(
        app,
        view.rawDiffPaneGeometry() orelse return error.ExpectedDiffPane,
        view.selectionStatusPresentation() orelse return error.ExpectedSelectionStatus,
        target,
    );
}

fn compareActionMouseEvent(app: *App, target: selection_action.StatusAction) !chasen.Event {
    const navigation_view = compareNavigation(app).view();
    var resolver = navigation_view.resolver();
    const body = navigation_view.bodyView(&resolver);
    return selectionActionMouseEvent(
        app,
        body.view.rawDiffPaneGeometry() orelse return error.ExpectedDiffPane,
        body.selectionStatusPresentation() orelse return error.ExpectedSelectionStatus,
        target,
    );
}

test "diff mouse selection owner is resolved from the active page surface" {
    var app: App = .{ .terminal_size = .{ .width = 80, .height = 20 } };
    app.pages.changes.selection_owner = .{ .diff_header = .{
        .identity = .{ .kind = .loaded_file, .path_key = "a" },
    } };

    const drag = app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) orelse return error.ExpectedDiffSelectionOwner;
    switch (drag) {
        .mouse_selection_drag => |continuation| switch (continuation.target) {
            .changes => {},
            else => return error.ExpectedChangesDiffDrag,
        },
        else => return error.ExpectedChangesDiffDrag,
    }

    app.active_page = .repository;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) == null);
}

test "root drag auto-scroll replaces generations and rejects stale ticks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 13 },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .sidebar_hidden = true,
                .focus = .diff,
                .display_mode = .unified,
            },
        } },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    defer app.shell_effects_state.deinit(allocator);
    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = 12, .row = diff_render.body_start_row },
    } };

    const body = shellLayout(&app).bodySize();
    const last_row = body.height - 1;
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 12, .row = last_row },
        .target = .{ .changes = .{ .col = 12, .row = last_row } },
    } }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    try std.testing.expect(app.pages.changes.selection_owner.activeDiff().?.moved);
    const first_generation = switch (tc.ctx._pending_everys[0].msg) {
        .drag_auto_scroll_tick => |generation| generation,
        else => return error.ExpectedDragAutoScrollTimer,
    };
    try std.testing.expectEqual(first_generation, app.drag_auto_scroll.scheduled_generation.?);

    tc.resetTransient();
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 13, .row = last_row },
        .target = .{ .changes = .{ .col = 13, .row = last_row } },
    } }, &tc.ctx);
    try std.testing.expectEqual(first_generation, app.drag_auto_scroll.active.?.generation);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());

    // Runtime drains the first admission. Crossing directly to the opposite
    // edge cancels A and admits B in the same update.
    tc.resetTransient();
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 12, .row = diff_render.body_start_row },
        .target = .{ .changes = .{ .col = 12, .row = diff_render.body_start_row } },
    } }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    const second_generation = switch (tc.ctx._pending_everys[0].msg) {
        .drag_auto_scroll_tick => |generation| generation,
        else => return error.ExpectedDragAutoScrollTimer,
    };
    try std.testing.expect(second_generation != first_generation);

    // A queued firing from the canceled timer is inert. B performs exactly
    // one row of semantic scroll and remains the repeating owner.
    tc.resetTransient();
    app.pages.changes.viewer.diff_scroll = 1;
    app.status.set("root diagnostic", .{});
    app.pages.changes.status.set("changes diagnostic", .{});
    const selection_before_stale = app.pages.changes.selection_owner;
    try app.update(.{ .drag_auto_scroll_tick = first_generation }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(std.meta.eql(selection_before_stale, app.pages.changes.selection_owner));
    try std.testing.expectEqualStrings("root diagnostic", app.status.text());
    try std.testing.expectEqualStrings("changes diagnostic", app.pages.changes.status.text());
    try std.testing.expect(tc.redrawSuppressed());

    tc.resetTransient();
    try app.update(.{ .drag_auto_scroll_tick = second_generation }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(app.drag_auto_scroll.active != null);

    // Reversing once more admits C. Repeated firings from that one accepted
    // generation advance beyond the small viewport, ignore a hunk header, and
    // resolve the endpoint in the second hunk without changing the start side.
    tc.resetTransient();
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 12, .row = last_row },
        .target = .{ .changes = .{ .col = 12, .row = last_row } },
    } }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    const third_generation = switch (tc.ctx._pending_everys[0].msg) {
        .drag_auto_scroll_tick => |generation| generation,
        else => return error.ExpectedDragAutoScrollTimer,
    };
    try std.testing.expect(third_generation != second_generation);

    var repeated_ticks: usize = 0;
    var encountered_non_selectable_row = false;
    while (app.pages.changes.selection_owner.activeDiff().?.focus.hunk_index == 0 and repeated_ticks < 8) {
        const focus_before = app.pages.changes.selection_owner.activeDiff().?.focus;
        tc.resetTransient();
        try app.update(.{ .drag_auto_scroll_tick = third_generation }, &tc.ctx);
        const focus_after = app.pages.changes.selection_owner.activeDiff().?.focus;
        encountered_non_selectable_row = encountered_non_selectable_row or std.meta.eql(focus_before, focus_after);
        repeated_ticks += 1;
    }
    const completed_focus = app.pages.changes.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expect(repeated_ticks >= 2);
    try std.testing.expect(encountered_non_selectable_row);
    try std.testing.expectEqual(@as(usize, 1), completed_focus.focus.hunk_index);
    try std.testing.expect(completed_focus.content == .unified_diff);
    try std.testing.expectEqual(third_generation, app.drag_auto_scroll.active.?.generation);

    // Release clears root intent before page completion, then reconciles the
    // admitted repeating timer to a cancel. Copy freezes the exact semantic
    // unified diff-row range reached by the repeated fake ticks.
    tc.resetTransient();
    try app.update(.{ .mouse_selection_release = .{
        .pointer = .{ .col = 12, .row = last_row },
        .target = .{ .changes = .{ .col = 12, .row = last_row } },
    } }, &tc.ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expect(app.pages.changes.completed_selection != null);
    app.pages.changes.viewer.diff_cursor = .{ .hunk_header = 1 };
    try app.update(.{ .changes = .{ .selection_action = .copy } }, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings(" one\n two\n-old\n+new\n four\n late one\n", tc.ctx._pending_clipboard_copies[0].text);

    const retained_token = app.pages.changes.completed_selection.?.token;
    const retained_generation = app.pages.changes.selection_generation;
    const hunk_text = "@@ -20,2 +20,2 @@ second\n late one\n-late old\n+late new\n";

    tc.resetTransient();
    const copies_before_keyboard_hunk = app.shell_effects_state.clipboard_copies.count();
    const keyboard_hunk = app.handleEvent(.{ .key_press = .{ .codepoint = 'Y' } }) orelse
        return error.ExpectedChangesKeyboardHunkCopy;
    try std.testing.expectEqual(App.Msg{ .changes = .copy_current_hunk }, keyboard_hunk);
    try app.update(keyboard_hunk, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(copies_before_keyboard_hunk + 1, app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings(hunk_text, tc.ctx._pending_clipboard_copies[0].text);
    try std.testing.expect(app.pages.changes.completed_selection.?.token.eql(retained_token));
    try std.testing.expectEqual(retained_generation, app.pages.changes.selection_generation);

    tc.resetTransient();
    const copies_before_mouse_hunk = app.shell_effects_state.clipboard_copies.count();
    const mouse_hunk = app.handleEvent(try changesActionMouseEvent(&app, .copy_hunk)) orelse
        return error.ExpectedChangesMouseHunkCopy;
    switch (mouse_hunk) {
        .changes => |msg| switch (msg) {
            .mouse_diff_press => {},
            else => return error.ExpectedChangesMouseHunkCopy,
        },
        else => return error.ExpectedChangesMouseHunkCopy,
    }
    try app.update(mouse_hunk, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(copies_before_mouse_hunk + 1, app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings(hunk_text, tc.ctx._pending_clipboard_copies[0].text);
    try std.testing.expect(app.pages.changes.completed_selection.?.token.eql(retained_token));
    try std.testing.expectEqual(retained_generation, app.pages.changes.selection_generation);

    // A later live drag can coexist with the retained status line. The fixed
    // header row must never become a semantic selection endpoint.
    tc.resetTransient();
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 10 } }, &tc.ctx);
    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = 12, .row = diff_render.body_start_row },
    } };
    const focus_before_action = app.pages.changes.selection_owner.activeDiff().?.focus;
    app.pages.changes.viewer.diff_scroll = 2;
    try app.update(.{ .changes = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = 12, .row = 1 },
    } } }, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.diff_scroll);
    try std.testing.expect(std.meta.eql(focus_before_action, app.pages.changes.selection_owner.activeDiff().?.focus));
}

test "root drag auto-scroll timer failures retain only retryable authority" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 12 },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .sidebar_hidden = true, .focus = .diff, .display_mode = .unified },
            .selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .content = .unified_diff,
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 0 },
                .anchor_cell = .{ .col = 12, .row = diff_render.body_start_row },
            } },
        } },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();
    const ids = [_][]const u8{ "full-0", "full-1", "full-2", "full-3", "full-4", "full-5", "full-6", "full-7" };
    for (ids) |id| try tc.ctx.timer().every(id, 1, .git_action_spinner_tick);

    const last_row = shellLayout(&app).body.height - 1;
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 12, .row = last_row },
        .target = .{ .changes = .{ .col = 12, .row = last_row } },
    } }, &tc.ctx);
    // An intent whose repeating timer was not admitted cannot claim runtime
    // ownership and fails closed.
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);

    tc.resetTransient();
    app.drag_auto_scroll.active = .{
        .generation = 12,
        .target = .changes,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 12, .row = last_row } },
    };
    app.drag_auto_scroll.scheduled_generation = 11;
    for (ids) |id| try tc.ctx.timer().cancel(id);
    try app.update(.close_help, &tc.ctx);
    // Cancel admission failure retains the old scheduled receipt and the new
    // desired generation so the next update can retry in order.
    try std.testing.expectEqual(@as(?u64, 11), app.drag_auto_scroll.scheduled_generation);
    try std.testing.expectEqual(@as(u64, 12), app.drag_auto_scroll.active.?.generation);

    tc.resetTransient();
    try app.update(.close_help, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    try std.testing.expectEqual(@as(?u64, 12), app.drag_auto_scroll.scheduled_generation);

    tc.resetTransient();
    var adapter = changesNavigation(&app).updateAdapter();
    const body_view = adapter.shared().navigation.view();
    app.pages.changes.viewer.diff_scroll = body_view.presentationDiffLineCount() -| body_view.view.diffVisibleRows();
    try app.update(.{ .drag_auto_scroll_tick = 12 }, &tc.ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
}

test "terminal resize clears diff selections before an effective-mode geometry change" {
    const allocator = std.testing.allocator;
    const content_selection = @import("../diff_surface/selection.zig");
    var app: App = .{
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            },
            .compare = .{
                .diff = .{ .load = app_test_support.loadState(app_test_support.loadedDiffOne()) },
                .basis = .{
                    .base = .{
                        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                        .display_name = try allocator.dupe(u8, "main"),
                        .kind = .local,
                    },
                    .head_display = try allocator.dupe(u8, "topic"),
                    .target = .{
                        .object_format = .sha1,
                        .base_oid = .{},
                        .head_oid = .{},
                        .diff_base_oid = .{},
                    },
                    .ahead_count = 1,
                },
            },
            .history = .{
                .current_view = .diff,
                .diff = .{ .load = app_test_support.loadState(app_test_support.loadedDiffOne()) },
            },
        },
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 20 },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    defer app.pages.compare.deinit(allocator);
    defer app.pages.history.deinit(allocator);

    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    };
    app.pages.changes.completed_selection = try content_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = content_selection.SourceBasis.init(.unstaged),
        .source_session_revision = app.pages.changes.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    app.pages.compare.diff.completed_selection = try content_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = content_selection.SourceBasis.init(.{ .range = "compare" }),
        .source_session_revision = app.pages.compare.diff.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    app.pages.history.diff.completed_selection = try content_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = content_selection.SourceBasis.init(.{ .range = "history" }),
        .source_session_revision = app.pages.history.diff.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    try std.testing.expect(app.pages.compare.diff.installPinnedSelectionBasis(app.pages.compare.currentTarget()));
    app.pages.history.diff.pinned_selection_basis = .init(
        app.pages.compare.currentTarget() orelse return error.ExpectedCompareTarget,
    );
    app.pages.changes.selection_owner = .{ .diff = selection };
    app.pages.compare.diff.selection_owner = .{ .diff = selection };
    app.pages.history.diff.selection_owner = .{ .diff = selection };
    app.drag_auto_scroll.active = .{
        .generation = 9,
        .target = .changes,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 20, .row = 10 } },
    };
    app.drag_auto_scroll.scheduled_generation = 9;
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const changes_token = app.pages.changes.completed_selection.?.token;
    const compare_token = app.pages.compare.diff.completed_selection.?.token;
    const history_token = app.pages.history.diff.completed_selection.?.token;
    const compare_pin = app.pages.compare.diff.pinned_selection_basis.?;
    const history_pin = app.pages.history.diff.pinned_selection_basis.?;
    const changes_revision = app.pages.changes.selection_layout_revision;
    const compare_revision = app.pages.compare.diff.selection_layout_revision;
    const history_revision = app.pages.history.diff.selection_layout_revision;

    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 21 } }, &tc.ctx);
    try std.testing.expect(app.pages.changes.completed_selection.?.token.eql(changes_token));
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(compare_token));
    try std.testing.expect(app.pages.history.diff.completed_selection.?.token.eql(history_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(compare_pin));
    try std.testing.expect(app.pages.history.diff.pinned_selection_basis.?.eql(history_pin));
    try std.testing.expectEqual(changes_revision, app.pages.changes.selection_layout_revision);
    try std.testing.expectEqual(compare_revision, app.pages.compare.diff.selection_layout_revision);
    try std.testing.expectEqual(history_revision, app.pages.history.diff.selection_layout_revision);

    app.pages.changes.selection_owner = .{ .diff = selection };
    app.pages.compare.diff.selection_owner = .{ .diff = selection };
    app.pages.history.diff.selection_owner = .{ .diff = selection };
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, &tc.ctx);

    try std.testing.expect(app.pages.changes.selection_owner == .none);
    try std.testing.expect(app.pages.compare.diff.selection_owner == .none);
    try std.testing.expect(app.pages.history.diff.selection_owner == .none);
    try std.testing.expect(app.pages.changes.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.completed_selection == null);
    try std.testing.expect(app.pages.history.diff.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis == null);
    try std.testing.expect(app.pages.history.diff.pinned_selection_basis == null);
    try std.testing.expectEqual(changes_revision + 1, app.pages.changes.selection_layout_revision);
    try std.testing.expectEqual(compare_revision + 1, app.pages.compare.diff.selection_layout_revision);
    try std.testing.expectEqual(history_revision + 1, app.pages.history.diff.selection_layout_revision);
    try std.testing.expectEqual(chasen.Size{ .width = 120, .height = 30 }, app.terminal_size);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
}

test "terminal resize preserves semantic keyboard line selection while focus loss clears it" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .focus = .diff, .sidebar_hidden = true },
            },
            .compare = .{ .diff = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .focus = .diff, .sidebar_hidden = true },
            } },
        },
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 32 },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    defer app.pages.compare.deinit(allocator);

    var selection = diff_selection.DragSelection.initKeyboardLine(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    );
    selection.updateKeyboardLine(.{ .hunk_index = 0, .line_index = 1 }, 2);
    app.pages.changes.selection_owner = .{ .diff = selection };
    app.pages.compare.diff.selection_owner = .{ .diff = selection };
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(
        content.col + 20,
        content.row + 5,
        .left,
        .release,
    )) == null);

    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &tc.ctx);
    try std.testing.expect(app.pages.changes.selection_owner.activeKeyboardLineSelection());
    try std.testing.expect(app.pages.compare.diff.selection_owner.activeKeyboardLineSelection());
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.selection_owner.activeDiff().?.selected_line_count);
    try std.testing.expectEqual(chasen.Size{ .width = 80, .height = 12 }, app.terminal_size);

    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(app.pages.changes.selection_owner == .none);
    try std.testing.expect(app.pages.compare.diff.selection_owner.activeKeyboardLineSelection());

    const resize_choice: diff_selection.KeyboardSideChoice = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .before = .{ .hunk_index = 0, .line_index = 2 },
        .after = .{ .hunk_index = 0, .line_index = 3 },
    };
    app.pages.changes.viewer.sidebar_hidden = false;
    app.pages.compare.diff.viewer.sidebar_hidden = false;
    app.pages.changes.selection_owner = .{ .keyboard_side_choice = resize_choice };
    app.pages.compare.diff.selection_owner = .{ .keyboard_side_choice = resize_choice };
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &tc.ctx);
    try std.testing.expect(app.pages.changes.selection_owner == .none);
    try std.testing.expect(app.pages.compare.diff.selection_owner == .none);

    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(.{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
    }, 0) };
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &tc.ctx);
    try std.testing.expect(app.pages.repository.activeKeyboardLineSelection());
    try std.testing.expect(!app.pages.repository.activeMouseOwner());

    app.active_page = .repository;
    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(!app.pages.repository.activeBorrowedSourceRange());
}

test "Compare retained actions route keyboard and mouse through App after narrow resize" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .compare,
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 12 },
        .pages = .{ .compare = .{
            .diff = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{
                    .sidebar_hidden = true,
                    .focus = .diff,
                    .display_mode = .side_by_side,
                },
            },
            .basis = .{
                .base = .{
                    .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                    .display_name = try allocator.dupe(u8, "main"),
                    .kind = .local,
                },
                .head_display = try allocator.dupe(u8, "topic"),
                .target = .{
                    .object_format = .sha1,
                    .base_oid = .{},
                    .head_oid = .{},
                    .diff_base_oid = .{},
                },
                .ahead_count = 1,
            },
        } },
    };
    defer app.pages.compare.deinit(allocator);
    defer app.shell_effects_state.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.pages.compare.diff.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .{ .source_side = .{ .side = .old } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = 20, .row = diff_render.body_start_row },
    } };
    const last_row = shellLayout(&app).body.height - 1;
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 20, .row = last_row },
        .target = .{ .compare = .{ .col = 20, .row = last_row } },
    } }, &ctx);
    const auto_scroll_generation = app.drag_auto_scroll.active.?.generation;
    try std.testing.expectEqual(auto_scroll_generation, app.drag_auto_scroll.scheduled_generation.?);

    var repeated_ticks: usize = 0;
    var crossed_presentation_only_row = false;
    while (app.pages.compare.diff.selection_owner.activeDiff().?.focus.hunk_index == 0 and repeated_ticks < 8) {
        const focus_before = app.pages.compare.diff.selection_owner.activeDiff().?.focus;
        try app.update(.{ .drag_auto_scroll_tick = auto_scroll_generation }, &ctx);
        const focus_after = app.pages.compare.diff.selection_owner.activeDiff().?.focus;
        crossed_presentation_only_row = crossed_presentation_only_row or std.meta.eql(focus_before, focus_after);
        repeated_ticks += 1;
    }
    const live = app.pages.compare.diff.selection_owner.activeDiff() orelse return error.ExpectedCompareDiffSelection;
    try std.testing.expect(repeated_ticks >= 2);
    try std.testing.expect(crossed_presentation_only_row);
    try std.testing.expectEqual(@as(usize, 1), live.focus.hunk_index);
    try std.testing.expect(live.selectedSide().? == .old);
    try std.testing.expectEqual(auto_scroll_generation, app.drag_auto_scroll.active.?.generation);

    try app.update(.{ .mouse_selection_release = .{
        .pointer = .{ .col = 20, .row = last_row },
        .target = .{ .compare = .{ .col = 20, .row = last_row } },
    } }, &ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.pages.compare.diff.completed_selection != null);
    try app.update(.{ .compare = .{ .common = .{ .shared = .{ .selection_action = .copy } } } }, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings(
        "one\ntwo\nold\nfour\nlate one\n",
        ctx._pending_clipboard_copies[0].text,
    );

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    app.pages.compare.diff.viewer.display_mode = .unified;
    try installRootCompareSelection(&app, allocator);
    const retained_token = app.pages.compare.diff.completed_selection.?.token;
    const retained_pin = app.pages.compare.diff.pinned_selection_basis.?;
    const retained_generation = app.pages.compare.diff.selection_generation;
    const keyboard_copy = app.handleEvent(.{ .key_press = .{ .codepoint = 'y' } }) orelse
        return error.ExpectedCompareKeyboardCopy;
    try std.testing.expectEqual(
        App.Msg{ .compare = .{ .common = .{ .shared = .{ .selection_action = .copy } } } },
        keyboard_copy,
    );
    try app.update(keyboard_copy, &ctx);
    try std.testing.expectEqual(@as(usize, 2), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings(" one\n two\n-old\n+new\n", ctx._pending_clipboard_copies[1].text);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expect(app.pages.compare.diff.retainedSelectionAdmitted(app.pages.compare.currentTarget()));

    const mouse_copy = app.handleEvent(try compareActionMouseEvent(&app, .copy)) orelse
        return error.ExpectedCompareMouseCopy;
    try std.testing.expectEqual(
        App.Msg{ .compare = .{ .common = .{ .shared = .{ .mouse_diff_press = switch (mouse_copy.compare.common.shared) {
            .mouse_diff_press => |point| point,
            else => return error.ExpectedCompareMouseCopy,
        } } } } },
        mouse_copy,
    );
    try app.update(mouse_copy, &ctx);
    try std.testing.expectEqual(@as(usize, 3), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings(" one\n two\n-old\n+new\n", ctx._pending_clipboard_copies[2].text);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    app.pages.compare.diff.viewer.diff_cursor = .{ .hunk_header = 0 };
    const hunk_text = "@@ -1,4 +1,4 @@ first\n one\n two\n-old\n+new\n four\n";
    const keyboard_hunk = app.handleEvent(.{ .key_press = .{ .codepoint = 'Y' } }) orelse
        return error.ExpectedCompareKeyboardHunkCopy;
    try std.testing.expectEqual(App.Msg{ .compare = .{ .common = .copy_current_hunk } }, keyboard_hunk);
    try app.update(keyboard_hunk, &ctx);
    try std.testing.expectEqual(@as(usize, 4), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings(hunk_text, ctx._pending_clipboard_copies[3].text);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expectEqual(retained_generation, app.pages.compare.diff.selection_generation);

    const older_request_id = ctx._pending_clipboard_copies[0].request_id;
    const replacement_failure_request_id = ctx._pending_clipboard_copies[1].request_id;
    const current_selection_request_id = ctx._pending_clipboard_copies[2].request_id;
    const keyboard_hunk_request_id = ctx._pending_clipboard_copies[3].request_id;
    ctx.runtimeClearPendingEffectCopies();

    const mouse_hunk = app.handleEvent(try compareActionMouseEvent(&app, .copy_hunk)) orelse
        return error.ExpectedCompareMouseHunkCopy;
    switch (mouse_hunk) {
        .compare => |msg| switch (msg) {
            .common => |common| switch (common) {
                .shared => |shared| switch (shared) {
                    .mouse_diff_press => {},
                    else => return error.ExpectedCompareMouseHunkCopy,
                },
                else => return error.ExpectedCompareMouseHunkCopy,
            },
            else => return error.ExpectedCompareMouseHunkCopy,
        },
        else => return error.ExpectedCompareMouseHunkCopy,
    }
    try app.update(mouse_hunk, &ctx);
    try std.testing.expectEqual(@as(usize, 5), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings(hunk_text, ctx._pending_clipboard_copies[0].text);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expectEqual(retained_generation, app.pages.compare.diff.selection_generation);
    const mouse_hunk_request_id = ctx._pending_clipboard_copies[0].request_id;
    inline for (.{ keyboard_hunk_request_id, mouse_hunk_request_id }) |request_id| {
        try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
            .request_id = request_id,
            .outcome = .sent,
        } } }, &ctx);
    }
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    // Success for an older generation must not clear the newer selection.
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = older_request_id,
        .outcome = .sent,
    } } }, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    // Success for the current generation clears both the retained bytes and
    // Compare's retained basis. A failed older request cannot clear a later
    // replacement.
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = current_selection_request_id,
        .outcome = .sent,
    } } }, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis == null);
    try installRootCompareSelection(&app, allocator);
    const replacement_token = app.pages.compare.diff.completed_selection.?.token;
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = replacement_failure_request_id,
        .outcome = .unsupported_runtime,
    } } }, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(replacement_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis != null);

    var keyboard_clear_view = compareNavigation(&app).view();
    var keyboard_clear_resolver = keyboard_clear_view.resolver();
    const keyboard_clear_body = keyboard_clear_view.bodyView(&keyboard_clear_resolver);
    const keyboard_anchor = keyboard_clear_body.captureSelectionViewportAnchor() orelse
        return error.ExpectedKeyboardClearAnchor;
    const keyboard_clear = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.escape } }) orelse
        return error.ExpectedCompareKeyboardClear;
    try std.testing.expectEqual(
        App.Msg{ .compare = .{ .common = .{ .shared = .{ .selection_action = .clear } } } },
        keyboard_clear,
    );
    try app.update(keyboard_clear, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis == null);
    var after_keyboard_view = compareNavigation(&app).view();
    var after_keyboard_resolver = after_keyboard_view.resolver();
    const after_keyboard_body = after_keyboard_view.bodyView(&after_keyboard_resolver);
    const expected_keyboard_scroll = after_keyboard_body.restoreSelectionViewportAnchor(keyboard_anchor);
    try std.testing.expectEqual(keyboard_anchor.raw_presentation_scroll, expected_keyboard_scroll);
    try std.testing.expectEqual(expected_keyboard_scroll, app.pages.compare.diff.viewer.diff_scroll);

    try installRootCompareSelection(&app, allocator);
    var mouse_clear_view = compareNavigation(&app).view();
    var mouse_clear_resolver = mouse_clear_view.resolver();
    const mouse_clear_body = mouse_clear_view.bodyView(&mouse_clear_resolver);
    const mouse_anchor = mouse_clear_body.captureSelectionViewportAnchor() orelse
        return error.ExpectedMouseClearAnchor;
    const mouse_clear = app.handleEvent(try compareActionMouseEvent(&app, .clear)) orelse
        return error.ExpectedCompareMouseClear;
    try app.update(mouse_clear, &ctx);
    try std.testing.expect(app.pages.compare.diff.completed_selection == null);
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis == null);
    var after_mouse_view = compareNavigation(&app).view();
    var after_mouse_resolver = after_mouse_view.resolver();
    const after_mouse_body = after_mouse_view.bodyView(&after_mouse_resolver);
    const expected_mouse_scroll = after_mouse_body.restoreSelectionViewportAnchor(mouse_anchor);
    try std.testing.expectEqual(mouse_anchor.raw_presentation_scroll, expected_mouse_scroll);
    try std.testing.expectEqual(expected_mouse_scroll, app.pages.compare.diff.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), app.shell_effects_state.clipboard_copies.count());
}

test "History accepted diff runs one root interaction and transition sequence" {
    const allocator = std.testing.allocator;
    const before = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const oldest = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const request: git_history.SelectionRequest = .{
        .snapshot_head = after,
        .intent = .{ .single = .{ .index = 0, .oid = after } },
        .basis = .{
            .object_format = .sha1,
            .before = .{ .commit = before },
            .after = after,
        },
    };
    var loaded = app_test_support.loadedDiffNested();
    loaded.reviewed_files = try allocator.alloc(bool, 2);
    @memset(loaded.reviewed_files, false);
    var app: App = .{
        .active_page = .history,
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 32 },
        .pages = .{ .history = .{
            .repo_epoch = 0,
            .load_state = .loaded,
            .current_view = .diff,
            .diff = .{
                .load = app_test_support.loadState(loaded),
                .viewer = .{ .focus = .diff },
                .accepted_repository_identity = .{ .repo_epoch = 0, .root_identity = null },
            },
        } },
    };
    switch (app.pages.history.diff.load.state) {
        .loaded => |*session| {
            session.reviewed_files_owned = true;
            session.loaded.collapsed_hunks = try session.arena.allocator().alloc(
                bool,
                session.loaded.document.totalHunks(),
            );
            @memset(session.loaded.collapsed_hunks, false);
        },
        else => unreachable,
    }
    app.pages.history.accepted = .{
        .request = request,
        .origin = .detached,
        .selected_parent_count = 1,
    };
    var catalog_page: git_history.Page = catalog_page: {
        const records = try allocator.alloc(git_history.Record, 3);
        var initialized: usize = 0;
        errdefer {
            for (records[0..initialized]) |*record| record.deinit(allocator);
            allocator.free(records);
        }
        records[0] = try historyRecordForRootTest(allocator, after, 1, .{ .available = before }, "accepted subject");
        initialized += 1;
        records[1] = try historyRecordForRootTest(allocator, before, 1, .{ .available = oldest }, "parent");
        initialized += 1;
        records[2] = try historyRecordForRootTest(allocator, oldest, 0, .true_root, "root");
        break :catalog_page .{
            .snapshot = .{
                .object_format = .sha1,
                .head = after,
                .display = .detached,
            },
            .records = records,
        };
    };
    defer catalog_page.deinit(allocator);
    try app.pages.history.catalog.replace(allocator, &catalog_page);
    app.pages.history.catalog.cursor = 2;
    app.pages.history.catalog.scroll = 1;
    app.pages.history.draft = .{ .range = 1 };
    defer app.pages.history.deinit(allocator);
    defer app.shell_effects_state.deinit(allocator);
    _ = app.pages.history.activation.activate(0, .immutable, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    // Diff text input retains priority over root page shortcuts.
    app.pages.history.diff.search.mode = true;
    const search_key = app.handleEvent(.{ .key_press = .{ .codepoint = '4' } }) orelse
        return error.ExpectedHistorySearchInput;
    try std.testing.expectEqual(
        App.Msg{ .history = .{ .common = .{ .shared = .{ .search_insert = '4' } } } },
        search_key,
    );
    try app.update(search_key, &ctx);
    const search_paste = app.handleEvent(.{ .paste = "needle" }) orelse
        return error.ExpectedHistorySearchPaste;
    try app.update(search_paste, &ctx);
    try std.testing.expectEqualStrings("4needle", app.pages.history.diff.search.input.slice());
    const cancel_search = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.escape } }) orelse
        return error.ExpectedHistorySearchCancel;
    try app.update(cancel_search, &ctx);
    try std.testing.expect(!app.pages.history.diff.search.mode);

    // History owns and suppresses reviewed actions at its adapter boundary for
    // both default and configured bindings; the shared state stays untouched.
    for ([_]chasen.Key{ .{ .codepoint = 'v' }, .{ .codepoint = 'H' } }) |key| {
        const msg = app.handleEvent(.{ .key_press = key }) orelse return error.ExpectedHistoryOwnedNoop;
        try std.testing.expectEqual(App.Msg{ .history = .owned_noop }, msg);
        try app.update(msg, &ctx);
    }
    var configured: keymap.Config = .{};
    configured.set(.mark_reviewed, .{ .plain_codepoint = 'x' });
    configured.set(.hide_reviewed, .{ .plain_codepoint = 'z' });
    app.keymap = keymap.Effective.fromConfig(configured);
    for ([_]chasen.Key{ .{ .codepoint = 'x' }, .{ .codepoint = 'z' } }) |key| {
        const msg = app.handleEvent(.{ .key_press = key }) orelse return error.ExpectedHistoryOwnedNoop;
        try std.testing.expectEqual(App.Msg{ .history = .owned_noop }, msg);
        try app.update(msg, &ctx);
    }
    app.keymap = .{};
    const accepted_loaded = switch (app.pages.history.diff.load.state) {
        .loaded => |*session| &session.loaded,
        else => return error.ExpectedLoadedHistory,
    };
    try std.testing.expect(!accepted_loaded.reviewed_files[0]);
    try std.testing.expect(!app.pages.history.diff.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.diff.reviewed_store.entries.count());

    // The same accepted surface routes both sidebar and diff pointer regions.
    var layout = shellLayout(&app);
    const sidebar_click = app.handleEvent(app_test_support.mouseEventTyped(
        layout.body.col + 1,
        layout.body.row + sidebar_header_rows,
        .left,
        .press,
    )) orelse return error.ExpectedHistorySidebarPress;
    try std.testing.expectEqual(
        App.Msg{ .history = .{ .common = .{ .shared = .{ .sidebar_click_node = 0 } } } },
        sidebar_click,
    );
    try app.update(sidebar_click, &ctx);

    accepted_loaded.toggleHunkFold(0, 0);
    app.pages.history.diff.viewer.display_mode = .side_by_side;
    app.pages.history.diff.viewer.diff_cursor = .{ .hunk_header = 1 };
    app.pages.history.diff.viewer.diff_scroll = 4;
    const retained_target = app.pages.history.diff.viewer.selected_target;
    const retained_node = app.pages.history.diff.viewer.selected_node;
    try std.testing.expect(file_tree.isCollapsed(&accepted_loaded.collapsed_dirs, "src"));
    try std.testing.expect(accepted_loaded.isHunkFolded(0, 0));

    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &ctx);
    try std.testing.expectEqual(chasen.Size{ .width = 80, .height = 24 }, app.terminal_size);
    try std.testing.expectEqual(retained_target, app.pages.history.diff.viewer.selected_target);
    try std.testing.expectEqual(retained_node, app.pages.history.diff.viewer.selected_node);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.pages.history.diff.viewer.display_mode);
    try std.testing.expect(file_tree.isCollapsed(&accepted_loaded.collapsed_dirs, "src"));
    try std.testing.expect(accepted_loaded.isHunkFolded(0, 0));
    try std.testing.expect(std.meta.eql(request, app.pages.history.accepted.?.request));
    try std.testing.expectEqual(@as(usize, 2), app.pages.history.catalog.cursor);
    try std.testing.expectEqual(@as(?usize, 1), app.pages.history.draft.anchor());
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.catalog.scroll);
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.diff.viewer.diff_scroll);

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    try std.testing.expectEqual(chasen.Size{ .width = 120, .height = 32 }, app.terminal_size);
    try std.testing.expectEqual(retained_target, app.pages.history.diff.viewer.selected_target);
    try std.testing.expectEqual(retained_node, app.pages.history.diff.viewer.selected_node);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.pages.history.diff.viewer.display_mode);
    try std.testing.expect(file_tree.isCollapsed(&accepted_loaded.collapsed_dirs, "src"));
    try std.testing.expect(accepted_loaded.isHunkFolded(0, 0));
    try std.testing.expect(std.meta.eql(request, app.pages.history.accepted.?.request));
    try std.testing.expectEqual(@as(usize, 2), app.pages.history.catalog.cursor);
    try std.testing.expectEqual(@as(?usize, 1), app.pages.history.draft.anchor());
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.catalog.scroll);
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.diff.viewer.diff_scroll);
    accepted_loaded.toggleHunkFold(0, 0);
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 12 } }, &ctx);
    layout = shellLayout(&app);

    const sidebar_width = sidebarWidth(layout.content.width, null);
    const diff_point = diff_surface.MousePoint{
        .col = sidebar_width + 20,
        .row = diff_render.body_start_row,
    };
    const diff_press = app.handleEvent(app_test_support.mouseEventTyped(
        layout.body.col + diff_point.col,
        layout.body.row + diff_point.row,
        .left,
        .press,
    )) orelse return error.ExpectedHistoryDiffPress;
    try std.testing.expectEqual(
        App.Msg{ .history = .{ .common = .{ .shared = .{ .mouse_diff_press = diff_point } } } },
        diff_press,
    );

    app.pages.history.diff.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .{ .source_side = .{ .side = .old } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = diff_point.col, .row = diff_point.row },
    } };
    const last_row = layout.body.height - 1;
    const drag = app.handleEvent(app_test_support.mouseEventTyped(
        layout.body.col + diff_point.col,
        layout.body.row + last_row,
        .left,
        .drag,
    )) orelse return error.ExpectedHistoryDrag;
    switch (drag) {
        .mouse_selection_drag => |continuation| switch (continuation.target) {
            .history => {},
            else => return error.ExpectedHistoryDrag,
        },
        else => return error.ExpectedHistoryDrag,
    }
    try app.update(drag, &ctx);
    const auto_scroll_generation = app.drag_auto_scroll.active.?.generation;
    try std.testing.expectEqual(auto_scroll_generation, app.drag_auto_scroll.scheduled_generation.?);
    var ticks: usize = 0;
    while (app.pages.history.diff.selection_owner.activeDiff().?.focus.hunk_index == 0 and ticks < 32) : (ticks += 1) {
        try app.update(.{ .drag_auto_scroll_tick = auto_scroll_generation }, &ctx);
    }
    try std.testing.expect(ticks >= 1);
    try std.testing.expectEqual(
        @as(usize, 1),
        app.pages.history.diff.selection_owner.activeDiff().?.focus.hunk_index,
    );

    // The transition snapshot comes from the live History owner, not a hand-
    // written policy value.
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.history, app.active_page);
    try std.testing.expectEqualStrings(
        "finish History mouse selection before switching pages",
        app.status.text(),
    );

    const release = app.handleEvent(app_test_support.mouseEventTyped(
        layout.body.col + diff_point.col,
        layout.body.row + last_row,
        .left,
        .release,
    )) orelse return error.ExpectedHistoryRelease;
    switch (release) {
        .mouse_selection_release => |continuation| switch (continuation.target) {
            .history => {},
            else => return error.ExpectedHistoryRelease,
        },
        else => return error.ExpectedHistoryRelease,
    }
    try app.update(release, &ctx);
    try std.testing.expect(app.pages.history.diff.completed_selection != null);
    try std.testing.expect(app.pages.history.diff.pinned_selection_basis != null);

    const copy = app.handleEvent(.{ .key_press = .{ .codepoint = 'y' } }) orelse
        return error.ExpectedHistorySelectionCopy;
    try std.testing.expectEqual(
        App.Msg{ .history = .{ .common = .{ .shared = .{ .selection_action = .copy } } } },
        copy,
    );
    try app.update(copy, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = ctx._pending_clipboard_copies[0].request_id,
        .outcome = .sent,
    } } }, &ctx);
    try std.testing.expect(app.pages.history.diff.completed_selection == null);
    try std.testing.expect(app.pages.history.diff.pinned_selection_basis == null);

    app.pages.history.diff.search.mode = true;
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.history, app.active_page);
    try std.testing.expectEqualStrings("finish History search before switching pages", app.status.text());
    app.pages.history.diff.search.mode = false;
    app.pages.history.diff.file_search.mode = true;
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.history, app.active_page);
    try std.testing.expectEqualStrings("finish History file search before switching pages", app.status.text());
    app.pages.history.diff.file_search.mode = false;

    // Picker/catalog and picker/diff loading are intentionally not transition
    // blockers. Exercise both pending tags without a state cross-product.
    const root_identity = @import("../../repo/root_capability.zig").Identity{ .device = 3, .inode = 5 };
    const catalog_identity = app.pages.history.activation.currentIdentity().?;
    app.pages.history.current_view = .picker;
    app.pages.history.load_state = .loading;
    app.pages.history.pending = .{ .catalog = .{
        .identity = catalog_identity,
        .root_identity = root_identity,
        .generation = 9,
        .request = .{ .initial = .reset },
    } };
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.config, app.active_page);

    app.active_page = .history;
    _ = app.pages.history.activation.activate(0, .immutable, .unavailable, .unavailable);
    app.pages.history.current_view = .picker;
    app.pages.history.load_state = .loading;
    app.pages.history.pending = .{ .diff = .{
        .identity = app.pages.history.activation.currentIdentity().?,
        .root_identity = root_identity,
        .generation = 10,
        .request = request,
    } };
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.config, app.active_page);
}

test "help overlay opens and closes before normal shortcuts" {
    var app: App = .{ .active_page = .repository };
    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(.{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
    }, 0) };

    const open_msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedOpenHelp;
    try app.update(open_msg, undefined);
    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);
    try std.testing.expect(!app.pages.repository.activeBorrowedSourceRange());

    const scroll_msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'j' } }) orelse return error.ExpectedHelpScroll;
    try std.testing.expectEqual(App.Msg.help_scroll_down, scroll_msg);

    const close_msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'q' } }) orelse return error.ExpectedCloseHelp;
    try std.testing.expectEqual(App.Msg.close_help, close_msg);
    try app.update(close_msg, undefined);
    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
}

test "help overlay reopen resets help scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 120, .height = 12 },
        .overlay = .{ .kind = .help, .help_scroll = 5 },
    };

    try app.update(.close_help, undefined);
    try app.update(.open_help, undefined);

    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.help_scroll);
}

test "prompt input stays above help overlay" {
    var app: App = .{
        .pages = .{ .changes = .{
            .search = .{ .mode = true },
        } },
    };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedPromptInput;
    try app.update(msg, undefined);

    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expectEqualStrings("?", app.pages.changes.search.input.slice());
}

test "mouse click focuses sidebar and diff panes" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_event = app_test_support.mouseEvent(content.col + 1, content.row + 2, .left);
    const sidebar_msg = app.handleEvent(sidebar_event) orelse return error.ExpectedSidebarMouseMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);

    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.changes.viewer.sidebar_width) + 1;
    const diff_event = app_test_support.mouseEvent(diff_col, content.row + 2, .left);
    const diff_msg = app.handleEvent(diff_event) orelse return error.ExpectedDiffMouseMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "mouse click selects sidebar file rows" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "mouse click toggles sidebar directory rows" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff, .selected_node = 1 },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer changesReload(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarDirectoryClickMessage;
    try app.update(msg, undefined);

    const loaded = changesNavigation(&app).activeLoadedDiff().?;
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
}

test "mouse click on sidebar header or blank body focuses only" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const header_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + app_shell_layout.page_bar_rows, .left)) orelse return error.ExpectedSidebarHeaderClickMessage;
    try app.update(header_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);

    app.pages.changes.viewer.focus = .diff;
    const blank_row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 2;
    const blank_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, blank_row, .left)) orelse return error.ExpectedSidebarBlankClickMessage;
    try app.update(blank_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.changes.viewer.selected_node);
}

test "mouse click uses filtered sidebar projection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    loaded.reviewed_files = try arena.allocator().alloc(bool, loaded.document.files.len);
    @memset(loaded.reviewed_files, false);
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .deleted);

    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{ .focus = .diff, .selected_node = 0 },
            .review_display = .{ .changed_file_filter = .deleted },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer changesReload(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedFilteredSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.changes.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "mouse wheel scrolls the pane under the pointer" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedSidebarWheelMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);

    changesNavigation(&app).selectFileAbsolute(std.testing.allocator, 0);
    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.changes.viewer.sidebar_width) + 1;
    const diff_msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_down)) orelse return error.ExpectedDiffWheelMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll > 0);
}

test "wheel redraw reaches root for meaningful sidebar transition complete noop and reverse" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff, .selected_target = .{ .diff_file = 0 }, .selected_node = 0 },
            .selection_owner = .{ .keyboard_side_choice = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .before = .{ .hunk_index = 0, .line_index = 0 },
                .after = .{ .hunk_index = 0, .line_index = 0 },
            } },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.update(.{ .changes = .mouse_sidebar_wheel_up }, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqual(changes_page.Focus.sidebar, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(diff_selection.Owner.none, app.pages.changes.selection_owner);

    ctx.resetRedrawSuppressed();
    try app.update(.{ .changes = .mouse_sidebar_wheel_up }, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());

    app.pages.changes.status.set("prior diagnostic", .{});
    ctx.resetRedrawSuppressed();
    try app.update(.{ .changes = .mouse_sidebar_wheel_up }, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());

    ctx.resetRedrawSuppressed();
    try app.update(.{ .changes = .mouse_sidebar_wheel_up }, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());

    ctx.resetRedrawSuppressed();
    try app.update(.{ .changes = .mouse_sidebar_wheel_down }, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.changes.viewer.selected_target.?);
}

test "wheel redraw reaches root for semantic vertical and horizontal edges" {
    const source: diff_source.SourceMode = .{ .no_index = .{ .left = "left", .right = "right" } };
    var vertical: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = source },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true, .display_mode = .unified },
            .selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .content = .unified_diff,
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 0 },
                .moved = true,
            } },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };
    var vertical_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer vertical_ctx.runtimeClearPendingEffectCopies();
    vertical.pages.changes.viewer.diff_cursor = changesNavigation(&vertical).view().selectedCoordinateAtOffset(0) orelse
        return error.ExpectedCursorOffset;
    const vertical_owner = vertical.pages.changes.selection_owner;
    const vertical_scroll_before = vertical.pages.changes.viewer.diff_scroll;
    const vertical_cursor_before = changesNavigation(&vertical).view().selectedDiffCursorOffset();
    vertical_ctx.resetRedrawSuppressed();
    try vertical.update(.{ .changes = .mouse_diff_wheel_down }, &vertical_ctx);
    try std.testing.expect(!vertical_ctx.redrawWasSuppressed());
    try std.testing.expect(
        vertical.pages.changes.viewer.diff_scroll != vertical_scroll_before or
            changesNavigation(&vertical).view().selectedDiffCursorOffset() != vertical_cursor_before,
    );
    try std.testing.expectEqual(changes_page.Focus.diff, vertical.pages.changes.viewer.focus);
    try std.testing.expect(vertical.pages.changes.selection_owner.activeMouseSelection());
    try std.testing.expectEqualDeep(vertical_owner, vertical.pages.changes.selection_owner);

    var reached_vertical_noop = false;
    for (0..128) |_| {
        vertical_ctx.resetRedrawSuppressed();
        try vertical.update(.{ .changes = .mouse_diff_wheel_down }, &vertical_ctx);
        if (vertical_ctx.redrawWasSuppressed()) {
            reached_vertical_noop = true;
            break;
        }
    }
    try std.testing.expect(reached_vertical_noop);
    const vertical_edge = changesNavigation(&vertical).view().selectedDiffCursorOffset() orelse
        return error.ExpectedCursorOffset;
    const vertical_edge_scroll = vertical.pages.changes.viewer.diff_scroll;
    try std.testing.expect(vertical_edge > 1);
    try std.testing.expectEqualDeep(vertical_owner, vertical.pages.changes.selection_owner);
    vertical_ctx.resetRedrawSuppressed();
    try vertical.update(.{ .changes = .mouse_diff_wheel_up }, &vertical_ctx);
    try std.testing.expect(!vertical_ctx.redrawWasSuppressed());
    try std.testing.expect(
        vertical.pages.changes.viewer.diff_scroll != vertical_edge_scroll or
            changesNavigation(&vertical).view().selectedDiffCursorOffset().? != vertical_edge,
    );
    try std.testing.expectEqualDeep(vertical_owner, vertical.pages.changes.selection_owner);

    var horizontal: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = source },
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{ .focus = .sidebar, .sidebar_hidden = true, .display_mode = .unified },
        } },
        .terminal_size = .{ .width = 40, .height = 12 },
    };
    var horizontal_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer horizontal_ctx.runtimeClearPendingEffectCopies();
    var meaningful_horizontal = false;
    var reached_horizontal_noop = false;
    for (0..256) |_| {
        horizontal_ctx.resetRedrawSuppressed();
        try horizontal.update(.{ .changes = .mouse_diff_wheel_right }, &horizontal_ctx);
        if (horizontal_ctx.redrawWasSuppressed()) {
            reached_horizontal_noop = true;
            break;
        }
        meaningful_horizontal = true;
    }
    try std.testing.expect(meaningful_horizontal);
    try std.testing.expect(reached_horizontal_noop);
    horizontal_ctx.resetRedrawSuppressed();
    try horizontal.update(.{ .changes = .mouse_diff_wheel_left }, &horizontal_ctx);
    try std.testing.expect(!horizontal_ctx.redrawWasSuppressed());
}

test "Compare wheel redraw reaches root for meaningful complete noop and reverse" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .compare,
        .allocator = allocator,
        .pages = .{ .compare = .{ .diff = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true, .display_mode = .unified },
        } } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };
    defer app.pages.compare.deinit(allocator);
    _ = app.pages.compare.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const view = compareNavigation(&app).view();
    var resolver = view.resolver();
    const body = view.bodyView(&resolver);
    app.pages.compare.diff.viewer.diff_cursor = body.selectedCoordinateAtOffset(0) orelse
        return error.ExpectedCursorOffset;
    const first_cursor = body.selectedDiffCursorOffset();
    try app.update(.{ .compare = .{ .common = .{ .shared = .mouse_diff_wheel_down } } }, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expect(body.selectedDiffCursorOffset() != first_cursor);

    var reached_noop = false;
    for (0..128) |_| {
        ctx.resetRedrawSuppressed();
        try app.update(.{ .compare = .{ .common = .{ .shared = .mouse_diff_wheel_down } } }, &ctx);
        if (ctx.redrawWasSuppressed()) {
            reached_noop = true;
            break;
        }
    }
    try std.testing.expect(reached_noop);
    const edge_cursor = body.selectedDiffCursorOffset();
    const edge_scroll = app.pages.compare.diff.viewer.diff_scroll;

    ctx.resetRedrawSuppressed();
    try app.update(.{ .compare = .{ .common = .{ .shared = .mouse_diff_wheel_up } } }, &ctx);
    try std.testing.expect(!ctx.redrawWasSuppressed());
    try std.testing.expect(
        app.pages.compare.diff.viewer.diff_scroll != edge_scroll or
            body.selectedDiffCursorOffset() != edge_cursor,
    );
}

test "mouse uses full body as diff pane while sidebar is hidden" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .focus = .sidebar,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) orelse return error.ExpectedHiddenSidebarMouseMessage;
    try app.update(msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
}

test "help overlay wheel redraw changes once skips at edge and reverses" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .help },
    };

    var ctx: chasen.Ctx(App.Msg) = .{};
    const max_scroll = app_view.helpMaxScroll(layoutSize(&app), app.active_page);
    try std.testing.expect(max_scroll > 0);
    app.overlay.help_scroll = max_scroll - 1;
    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedHelpWheelMessage;
    try std.testing.expectEqual(App.Msg.help_scroll_down, msg);
    try app.update(msg, &ctx);
    try std.testing.expectEqual(max_scroll, app.overlay.help_scroll);
    try std.testing.expect(!ctx.redrawWasSuppressed());

    ctx.resetRedrawSuppressed();
    try app.update(msg, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());

    ctx.resetRedrawSuppressed();
    try app.update(.help_scroll_up, &ctx);
    try std.testing.expectEqual(max_scroll - 1, app.overlay.help_scroll);
    try std.testing.expect(!ctx.redrawWasSuppressed());

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "push error overlay wheel redraw changes once skips at edge and reverses" {
    const long_message =
        "line 1\nline 2\nline 3\nline 4\nline 5\n" ++
        "line 6\nline 7\nline 8\nline 9\nline 10\n";
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .remote_workflow = .{ .push_error_message = try std.testing.allocator.dupe(u8, long_message) },
    };
    defer app.remote_workflow.deinit(std.testing.allocator);
    app.overlay.openPushError();

    var ctx: chasen.Ctx(App.Msg) = .{};
    const max_scroll = app_view.pushErrorMaxScroll(layoutSize(&app), app.remote_workflow.push_error_message);
    try std.testing.expect(max_scroll > 0);
    app.overlay.push_error_scroll = max_scroll - 1;
    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedPushErrorWheelMessage;
    try std.testing.expectEqual(App.Msg.push_error_scroll_down, msg);
    try app.update(msg, &ctx);
    try std.testing.expectEqual(max_scroll, app.overlay.push_error_scroll);
    try std.testing.expect(!ctx.redrawWasSuppressed());

    ctx.resetRedrawSuppressed();
    try app.update(msg, &ctx);
    try std.testing.expect(ctx.redrawWasSuppressed());

    ctx.resetRedrawSuppressed();
    try app.update(.push_error_scroll_up, &ctx);
    try std.testing.expectEqual(max_scroll - 1, app.overlay.push_error_scroll);
    try std.testing.expect(!ctx.redrawWasSuppressed());

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "confirmation overlay blocks mouse clicks and wheels" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .focus = .diff,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .push_branch },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) == null);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.changes.viewer.selected_target.?);
}

test "terminal resize clamps push error scroll" {
    const long_message =
        "line 1\nline 2\nline 3\nline 4\nline 5\n" ++
        "line 6\nline 7\nline 8\nline 9\nline 10\n";
    var app: App = .{
        .terminal_size = .{ .width = 40, .height = 8 },
        .remote_workflow = .{ .push_error_message = try std.testing.allocator.dupe(u8, long_message) },
        .overlay = .{ .kind = .push_error, .push_error_scroll = 99 },
    };
    defer app.remote_workflow.deinit(std.testing.allocator);

    try app.update(.{ .terminal_resized = .{ .width = 100, .height = 12 } }, undefined);

    try std.testing.expectEqual(
        app_view.pushErrorMaxScroll(layoutSize(&app), app.remote_workflow.push_error_message),
        app.overlay.push_error_scroll,
    );
}

test "mouse horizontal wheel scrolls diff pane horizontally" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .focus = .sidebar,
                .display_mode = .unified,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.changes.viewer.sidebar_width) + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_right)) orelse return error.ExpectedHorizontalWheelMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expect(app.pages.changes.viewer.diff_horizontal_scroll > 0);
}

test "footer status click copies full page diagnostic across shared screens" {
    const allocator = std.testing.allocator;
    const status_text = "警告: clipped footerでも保持しているmessage全体をcopyする";
    const page_ids = [_]page.Id{ .changes, .repository, .history, .compare };

    for (page_ids, 0..) |page_id, index| {
        var app: App = .{
            .active_page = page_id,
            .terminal_size = if (index == 0)
                .{ .width = 34, .height = 8 }
            else
                .{ .width = 29, .height = 5 },
        };
        defer app.shell_effects_state.deinit(allocator);
        const page_status = switch (page_id) {
            .changes => &app.pages.changes.status,
            .repository => &app.pages.repository.status,
            .history => &app.pages.history.status,
            .compare => &app.pages.compare.status,
            .config => unreachable,
        };
        page_status.set("{s}", .{status_text});

        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        const msg = footerStatusPress(&app) orelse return error.ExpectedFooterStatusCopy;
        switch (msg) {
            .copy_footer_status => {},
            else => return error.ExpectedFooterStatusCopy,
        }
        try app.update(msg, &ctx);

        try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
        const entry = ctx._pending_clipboard_copies[0];
        try std.testing.expectEqualStrings(status_text, entry.text);
        try std.testing.expectEqualStrings("", page_status.text());
        try std.testing.expectEqual(@as(usize, 1), app.shell_effects_state.clipboard_copies.count());
        const pending = app.shell_effects_state.clipboard_copies.get(entry.request_id.id) orelse
            return error.ExpectedClipboardState;
        try std.testing.expectEqual(page_id, pending.origin.page.page_id);

        try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
            .request_id = entry.request_id,
            .outcome = .sent,
        } } }, &ctx);
        try std.testing.expectEqualStrings("clipboard copy sent: status message", page_status.text());
        try std.testing.expectEqual(@as(usize, 0), app.shell_effects_state.clipboard_copies.count());
    }
}

test "footer status click copies shell priority before revealing page completion" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 12 },
    };
    defer app.shell_effects_state.deinit(allocator);
    app.pages.changes.status.set("page diagnostic", .{});
    app.status.set("shell notification", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    const msg = footerStatusPress(&app) orelse return error.ExpectedFooterStatusCopy;
    try app.update(msg, &ctx);

    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("shell notification", entry.text);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("page diagnostic", app.pages.changes.status.text());

    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = entry.request_id,
        .outcome = .unsupported_runtime,
    } } }, &ctx);
    try std.testing.expectEqualStrings(
        "clipboard copy unavailable: status message",
        app.pages.changes.status.text(),
    );
}

test "footer status click respects text input overlay and spinner mouse blockers" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 12 },
    };
    app.pages.changes.status.set("changes diagnostic", .{});
    try std.testing.expect(footerStatusPress(&app) != null);

    app.pages.changes.search.mode = true;
    try std.testing.expect(footerStatusPress(&app) == null);
    app.pages.changes.search.mode = false;

    app.overlay.openHelpForPage(.changes);
    try std.testing.expect(footerStatusPress(&app) == null);
    app.overlay.close();

    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .push });
    action_lifecycle.testing.setSpinner(&app.action_runtime, 1, false);
    try std.testing.expect(footerStatusPress(&app) == null);
}

test "mouse events are ignored outside body and prompt modes" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(-1, 1, .left)) == null);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const footer_row: i16 = @intCast(content.row + terminalBodyHeight(layoutSize(&app).height));
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, footer_row, .left)) == null);

    app.pages.changes.search.mode = true;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 1, .left)) == null);
}

test "mouse release and motion events are ignored" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(content.col + 1, content.row + 1, .left, .release)) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(content.col + 1, content.row + 1, .left, .motion)) == null);
}

test "search overflow reports query status for insert and paste" {
    var app: App = .{
        .pages = .{ .changes = .{ .search = .{ .mode = true } } },
    };
    @memset(&app.pages.changes.search.input.buffer, 'x');
    app.pages.changes.search.input.len = app.pages.changes.search.input.buffer.len;
    app.pages.changes.search.input.cursor = app.pages.changes.search.input.buffer.len;

    try app.update(.{ .changes = .{ .search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.changes.status.text());

    app.status.clear();
    try app.update(.{ .changes = .{ .search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.changes.status.text());
}

test "file search overflow reports query status for insert and paste" {
    var app: App = .{
        .pages = .{ .changes = .{ .file_search = .{ .mode = true } } },
    };
    @memset(&app.pages.changes.file_search.input.buffer, 'x');
    app.pages.changes.file_search.input.len = app.pages.changes.file_search.input.buffer.len;
    app.pages.changes.file_search.input.cursor = app.pages.changes.file_search.input.buffer.len;

    try app.update(.{ .changes = .{ .file_search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.changes.status.text());

    app.status.clear();
    try app.update(.{ .changes = .{ .file_search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.changes.status.text());
}

test "repo picker filter overflow reports status for insert and paste" {
    var app: App = .{
        .repo_session = .{
            .repo_picker = .{
                .mode = true,
                .input_mode = .filter,
            },
        },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    @memset(&app.repo_session.repo_picker.list.input.buffer, 'x');
    app.repo_session.repo_picker.list.input.len = app.repo_session.repo_picker.list.input.buffer.len;
    app.repo_session.repo_picker.list.input.cursor = app.repo_session.repo_picker.list.input.buffer.len;

    try app.update(.{ .repo_picker_insert = 'y' }, &ctx);
    try std.testing.expectEqualStrings("repository filter is too long", app.status.text());

    app.status.clear();
    try app.update(.{ .repo_picker_paste = "y" }, &ctx);
    try std.testing.expectEqualStrings("repository filter is too long", app.status.text());
}

test "page bar rule is dead chrome in normal and compact layouts" {
    var app: App = .{ .terminal_size = .{ .width = 100, .height = 20 } };
    const normal = shellLayout(&app);
    const normal_bar = normal.page_bar orelse return error.ExpectedPageBar;
    try std.testing.expectEqual(app_shell_layout.page_bar_rows, normal_bar.height);
    const repository_tab = page.tab(.repository);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        normal_bar.col + repository_tab.col,
        normal_bar.row + app_shell_layout.page_bar_rule_row,
        .left,
    )) == null);

    app.terminal_size = .{ .width = 20, .height = 3 };
    const compact = shellLayout(&app);
    const compact_bar = compact.page_bar orelse return error.ExpectedCompactPageBar;
    try std.testing.expectEqual(@as(u16, 0), compact.body.height);
    try std.testing.expectEqual(App.Msg{ .switch_page = .changes }, app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + 1,
        compact_bar.row + app_shell_layout.page_bar_label_row,
        .left,
    )).?);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + repository_tab.col,
        compact_bar.row + app_shell_layout.page_bar_label_row,
        .left,
    )) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + 1,
        compact_bar.row + app_shell_layout.page_bar_rule_row,
        .left,
    )) == null);
}

test "direct nested Changes message uses the same update owner as keyboard input" {
    var direct: App = .{ .allocator = std.testing.allocator };
    var keyboard: App = .{ .allocator = std.testing.allocator };
    var direct_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var keyboard_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try direct.update(.{ .changes = .toggle_focus }, &direct_ctx);
    const keyboard_msg = keyboard.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.tab } }) orelse return error.ExpectedChangesMessage;
    try std.testing.expectEqual(App.Msg{ .changes = .toggle_focus }, keyboard_msg);
    try keyboard.update(keyboard_msg, &keyboard_ctx);

    try std.testing.expectEqual(changes_page.Focus.diff, direct.pages.changes.viewer.focus);
    try std.testing.expectEqual(direct.pages.changes.viewer.focus, keyboard.pages.changes.viewer.focus);
}

test "normal and help commit keys use the same nested Changes adapter" {
    const repo: repo_discovery.RepoEntry = .{
        .label = "repo",
        .display_path = "/repo",
        .canonical_root = "/repo",
    };
    var normal: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = repo } },
        },
    };
    var help: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = repo } },
        },
    };
    help.overlay.openHelpForPage(.changes);
    var normal_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var help_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const normal_msg = normal.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedChangesMessage;
    const help_msg = help.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedChangesMessage;
    try std.testing.expectEqual(App.Msg{ .changes = .enter_commit_panel }, normal_msg);
    try std.testing.expectEqual(normal_msg, help_msg);

    try normal.update(normal_msg, &normal_ctx);
    try help.update(help_msg, &help_ctx);
    try std.testing.expect(normal.local_workflow.commit_panel.is_open);
    try std.testing.expect(help.local_workflow.commit_panel.is_open);
    try std.testing.expect(!help.overlay.isHelp());
}

test "focus loss terminates selection without a deferred result" {
    var app: App = .{
        .pages = .{ .changes = .{
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .config = .{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } },
    };
    _ = activateChanges(&app);
    app.pages.changes.auto_reload = .init(.inherit, .{}, app.config.source);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.drag_auto_scroll.active = .{
        .generation = 3,
        .target = .changes,
        .intent = .{ .direction = .up, .endpoint = .{ .col = 4, .row = 3 } },
    };
    app.drag_auto_scroll.scheduled_generation = 3;

    try std.testing.expectEqual(App.Msg.focus_lost, app.handleEvent(.focus_out).?);
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.changes.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_cancels_len);

    try app.update(.auto_reload_tick, &ctx);
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const cycle_id = task.background_cycle_id.?;
    const generation = task.generation;
    DiffLoadTask.destroy(task, std.testing.allocator);
    _ = app.pages.changes.load.clearPendingIfCurrent(.{ .diff_load = generation });
    changesReload(&app).clearPendingReloadIfGeneration(std.testing.allocator, generation);
    app.pages.changes.auto_reload.finishMember(cycle_id, .source);
    try std.testing.expect(app.pages.changes.auto_reload.background_cycle == null);
}
