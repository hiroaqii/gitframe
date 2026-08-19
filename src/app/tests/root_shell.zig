//! Root-shell input and lifecycle integration tests.

const std = @import("std");
const chasen = @import("chasen");
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
const review_page = @import("../pages/review.zig");
const review_navigation = @import("../pages/review/navigation.zig");
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

fn reviewNavigation(app: *App) review_navigation.Controller {
    const size = shellLayout(app).bodySize();
    const repo = app.repo_session.view();
    return .{
        .page = &app.pages.review,
        .repo_root = repo.activeRoot(),
        .repo_epoch = repo.epoch(),
        .root_identity = repo.activeIdentity(),
        .layout = .{ .width = size.width, .height = size.height },
    };
}

fn installRootReviewSelection(app: *App, allocator: std.mem.Allocator) !void {
    app.pages.review.clearRetainedSelection(allocator);
    const loaded = switch (app.pages.review.load.state) {
        .loaded => |*session| &session.loaded,
        else => return error.ExpectedLoadedReview,
    };
    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    };
    app.pages.review.completed_selection = try diff_surface.selection.buildParsed(allocator, .{
        .repo_epoch = app.repo_session.view().epoch(),
        .root_identity = app.repo_session.view().activeIdentity(),
        .source = diff_surface.selection.SourceBasis.init(review_page.selection_source),
        .source_session_revision = app.pages.review.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init(loaded.text) },
    }, loaded.document.files[0], selection);
    _ = selection_action.advanceGeneration(&app.pages.review.selection_generation);
    if (!app.pages.review.installPinnedSelectionBasis()) return error.ExpectedReviewSelectionPin;
}

fn reviewActionMouseEvent(app: *App, target: selection_action.Action) !chasen.Event {
    const navigation_view = reviewNavigation(app).view();
    var resolver = navigation_view.resolver();
    const body = navigation_view.bodyView(&resolver);
    const presentation = body.selectionStatusPresentation() orelse return error.ExpectedSelectionStatus;
    const raw = body.view.rawDiffPaneGeometry() orelse return error.ExpectedDiffPane;
    const action_layout = diff_surface.selection_action.statusLayout(
        .{ .col = 1, .width = raw.width - 1 },
        presentation,
    );
    const region = switch (target) {
        .copy => action_layout.copy orelse return error.ExpectedCopyAction,
        .clear => action_layout.clear orelse return error.ExpectedClearAction,
    };
    const layout = shellLayout(app);
    return app_test_support.mouseEvent(
        layout.body.col + raw.col + region.col,
        layout.body.row + 1,
        .left,
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
        .side = .new,
        .mode = .line,
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
    try std.testing.expect(completed_focus.side == .new);
    try std.testing.expectEqual(third_generation, app.drag_auto_scroll.active.?.generation);

    // Release clears root intent before page completion, then reconciles the
    // admitted repeating timer to a cancel. Copy freezes the exact semantic
    // new-side range reached by the repeated fake ticks.
    tc.resetTransient();
    try app.update(.{ .mouse_selection_release = .{
        .pointer = .{ .col = 12, .row = last_row },
        .target = .{ .changes = .{ .col = 12, .row = last_row } },
    } }, &tc.ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expect(app.pages.changes.completed_selection != null);
    try app.update(.{ .changes = .{ .selection_action = .copy } }, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("one\ntwo\nnew\nfour\nlate one\n", tc.ctx._pending_clipboard_copies[0].text);

    // A later live drag can coexist with the retained status line. The fixed
    // header row must never become a semantic selection endpoint.
    tc.resetTransient();
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 10 } }, &tc.ctx);
    app.pages.changes.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
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
                .side = .new,
                .mode = .line,
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

test "terminal resize cancels live drag before geometry and retains completed selection" {
    const allocator = std.testing.allocator;
    const content_selection = @import("../diff_surface/selection.zig");
    var app: App = .{
        .pages = .{
            .changes = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            },
            .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .basis = .{
                    .base = .{
                        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                        .display_name = try allocator.dupe(u8, "main"),
                        .kind = .local,
                    },
                    .head_display = try allocator.dupe(u8, "topic"),
                    .target = .{
                        .object_format = .sha1,
                        .source_kind = .branch_range,
                        .base_oid = .{},
                        .head_oid = .{},
                        .diff_base_oid = .{},
                    },
                    .ahead_count = 1,
                },
            },
        },
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 20 },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    defer app.pages.review.deinit(allocator);

    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
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
    const retained_token = app.pages.changes.completed_selection.?.token;
    app.pages.review.completed_selection = try content_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = content_selection.SourceBasis.init(.{ .range = "review" }),
        .source_session_revision = app.pages.review.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    try std.testing.expect(app.pages.review.installPinnedSelectionBasis());
    const review_retained_token = app.pages.review.completed_selection.?.token;
    const review_retained_pin = app.pages.review.pinned_selection_basis.?;
    app.pages.changes.selection_owner = .{ .diff = selection };
    app.pages.review.selection_owner = .{ .diff = selection };
    app.drag_auto_scroll.active = .{
        .generation = 9,
        .target = .changes,
        .intent = .{ .direction = .down, .endpoint = .{ .col = 20, .row = 10 } },
    };
    app.drag_auto_scroll.scheduled_generation = 9;
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, &tc.ctx);

    try std.testing.expect(app.pages.changes.selection_owner == .none);
    try std.testing.expect(app.pages.review.selection_owner == .none);
    try std.testing.expect(app.pages.changes.completed_selection != null);
    try std.testing.expect(app.pages.changes.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.review.completed_selection != null);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(review_retained_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis.?.eql(review_retained_pin));
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
            .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
                .viewer = .{ .focus = .diff, .sidebar_hidden = true },
            },
        },
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 32 },
    };
    defer changesReload(&app).clearLoadedDiff(allocator);
    defer app.pages.review.deinit(allocator);

    var selection = diff_selection.DragSelection.initKeyboardLine(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    );
    selection.updateKeyboardLine(.{ .hunk_index = 0, .line_index = 1 }, 2);
    app.pages.changes.selection_owner = .{ .diff = selection };
    app.pages.review.selection_owner = .{ .diff = selection };
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
    try std.testing.expect(app.pages.review.selection_owner.activeKeyboardLineSelection());
    try std.testing.expectEqual(@as(usize, 2), app.pages.changes.selection_owner.activeDiff().?.selected_line_count);
    try std.testing.expectEqual(chasen.Size{ .width = 80, .height = 12 }, app.terminal_size);

    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(app.pages.changes.selection_owner == .none);
    try std.testing.expect(app.pages.review.selection_owner.activeKeyboardLineSelection());

    app.pages.repository.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(.{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
        .path = "main.zig",
        .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
    }, 0) };
    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &tc.ctx);
    try std.testing.expect(app.pages.repository.activeKeyboardLineSelection());
    try std.testing.expect(!app.pages.repository.activeMouseOwner());

    app.active_page = .repository;
    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(!app.pages.repository.activeBorrowedSourceRange());
}

test "Review retained actions route keyboard and mouse through App after narrow resize" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .review,
        .allocator = allocator,
        .terminal_size = .{ .width = 120, .height = 12 },
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .sidebar_hidden = true,
                .focus = .diff,
                .display_mode = .side_by_side,
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
                    .source_kind = .branch_range,
                    .base_oid = .{},
                    .head_oid = .{},
                    .diff_base_oid = .{},
                },
                .ahead_count = 1,
            },
        } },
    };
    defer app.pages.review.deinit(allocator);
    defer app.shell_effects_state.deinit(allocator);
    _ = app.pages.review.activate(app.repo_session.repo_epoch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.pages.review.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .old,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = 20, .row = diff_render.body_start_row },
    } };
    const last_row = shellLayout(&app).body.height - 1;
    try app.update(.{ .mouse_selection_drag = .{
        .pointer = .{ .col = 20, .row = last_row },
        .target = .{ .review = .{ .col = 20, .row = last_row } },
    } }, &ctx);
    const auto_scroll_generation = app.drag_auto_scroll.active.?.generation;
    try std.testing.expectEqual(auto_scroll_generation, app.drag_auto_scroll.scheduled_generation.?);

    var repeated_ticks: usize = 0;
    var crossed_presentation_only_row = false;
    while (app.pages.review.selection_owner.activeDiff().?.focus.hunk_index == 0 and repeated_ticks < 8) {
        const focus_before = app.pages.review.selection_owner.activeDiff().?.focus;
        try app.update(.{ .drag_auto_scroll_tick = auto_scroll_generation }, &ctx);
        const focus_after = app.pages.review.selection_owner.activeDiff().?.focus;
        crossed_presentation_only_row = crossed_presentation_only_row or std.meta.eql(focus_before, focus_after);
        repeated_ticks += 1;
    }
    const live = app.pages.review.selection_owner.activeDiff() orelse return error.ExpectedReviewDiffSelection;
    try std.testing.expect(repeated_ticks >= 2);
    try std.testing.expect(crossed_presentation_only_row);
    try std.testing.expectEqual(@as(usize, 1), live.focus.hunk_index);
    try std.testing.expect(live.side == .old);
    try std.testing.expectEqual(auto_scroll_generation, app.drag_auto_scroll.active.?.generation);

    try app.update(.{ .mouse_selection_release = .{
        .pointer = .{ .col = 20, .row = last_row },
        .target = .{ .review = .{ .col = 20, .row = last_row } },
    } }, &ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.pages.review.completed_selection != null);
    try app.update(.{ .review = .{ .shared = .{ .selection_action = .copy } } }, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings(
        "one\ntwo\nold\nfour\nlate one\n",
        ctx._pending_clipboard_copies[0].text,
    );

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 32 } }, &ctx);
    app.pages.review.viewer.display_mode = .unified;
    try installRootReviewSelection(&app, allocator);
    const retained_token = app.pages.review.completed_selection.?.token;
    const retained_pin = app.pages.review.pinned_selection_basis.?;
    const keyboard_copy = app.handleEvent(.{ .key_press = .{ .codepoint = 'y' } }) orelse
        return error.ExpectedReviewKeyboardCopy;
    try std.testing.expectEqual(
        App.Msg{ .review = .{ .shared = .{ .selection_action = .copy } } },
        keyboard_copy,
    );
    try app.update(keyboard_copy, &ctx);
    try std.testing.expectEqual(@as(usize, 2), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("one\ntwo\nnew\n", ctx._pending_clipboard_copies[1].text);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis.?.eql(retained_pin));

    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &ctx);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis.?.eql(retained_pin));
    try std.testing.expect(app.pages.review.retainedSelectionAdmitted());

    const mouse_copy = app.handleEvent(try reviewActionMouseEvent(&app, .copy)) orelse
        return error.ExpectedReviewMouseCopy;
    try std.testing.expectEqual(
        App.Msg{ .review = .{ .shared = .{ .mouse_diff_press = switch (mouse_copy.review.shared) {
            .mouse_diff_press => |point| point,
            else => return error.ExpectedReviewMouseCopy,
        } } } },
        mouse_copy,
    );
    try app.update(mouse_copy, &ctx);
    try std.testing.expectEqual(@as(usize, 3), app.shell_effects_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("one\ntwo\nnew\n", ctx._pending_clipboard_copies[2].text);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis.?.eql(retained_pin));

    // Success for an older generation must not clear the newer selection.
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = ctx._pending_clipboard_copies[0].request_id,
        .outcome = .sent,
    } } }, &ctx);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis.?.eql(retained_pin));

    // Success for the current generation clears both the retained bytes and
    // Review's pinned basis. A failed older request cannot clear a later
    // replacement.
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = ctx._pending_clipboard_copies[2].request_id,
        .outcome = .sent,
    } } }, &ctx);
    try std.testing.expect(app.pages.review.completed_selection == null);
    try std.testing.expect(app.pages.review.pinned_selection_basis == null);
    try installRootReviewSelection(&app, allocator);
    const replacement_token = app.pages.review.completed_selection.?.token;
    try app.update(.{ .shell_effect_finished = .{ .clipboard = .{
        .request_id = ctx._pending_clipboard_copies[1].request_id,
        .outcome = .unsupported_runtime,
    } } }, &ctx);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(replacement_token));
    try std.testing.expect(app.pages.review.pinned_selection_basis != null);

    var keyboard_clear_view = reviewNavigation(&app).view();
    var keyboard_clear_resolver = keyboard_clear_view.resolver();
    const keyboard_clear_body = keyboard_clear_view.bodyView(&keyboard_clear_resolver);
    const keyboard_anchor = keyboard_clear_body.captureSelectionViewportAnchor() orelse
        return error.ExpectedKeyboardClearAnchor;
    const keyboard_clear = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.escape } }) orelse
        return error.ExpectedReviewKeyboardClear;
    try std.testing.expectEqual(
        App.Msg{ .review = .{ .shared = .{ .selection_action = .clear } } },
        keyboard_clear,
    );
    try app.update(keyboard_clear, &ctx);
    try std.testing.expect(app.pages.review.completed_selection == null);
    try std.testing.expect(app.pages.review.pinned_selection_basis == null);
    var after_keyboard_view = reviewNavigation(&app).view();
    var after_keyboard_resolver = after_keyboard_view.resolver();
    const after_keyboard_body = after_keyboard_view.bodyView(&after_keyboard_resolver);
    const expected_keyboard_scroll = after_keyboard_body.restoreSelectionViewportAnchor(keyboard_anchor);
    try std.testing.expectEqual(keyboard_anchor.raw_presentation_scroll, expected_keyboard_scroll);
    try std.testing.expectEqual(expected_keyboard_scroll, app.pages.review.viewer.diff_scroll);

    try installRootReviewSelection(&app, allocator);
    var mouse_clear_view = reviewNavigation(&app).view();
    var mouse_clear_resolver = mouse_clear_view.resolver();
    const mouse_clear_body = mouse_clear_view.bodyView(&mouse_clear_resolver);
    const mouse_anchor = mouse_clear_body.captureSelectionViewportAnchor() orelse
        return error.ExpectedMouseClearAnchor;
    const mouse_clear = app.handleEvent(try reviewActionMouseEvent(&app, .clear)) orelse
        return error.ExpectedReviewMouseClear;
    try app.update(mouse_clear, &ctx);
    try std.testing.expect(app.pages.review.completed_selection == null);
    try std.testing.expect(app.pages.review.pinned_selection_basis == null);
    var after_mouse_view = reviewNavigation(&app).view();
    var after_mouse_resolver = after_mouse_view.resolver();
    const after_mouse_body = after_mouse_view.bodyView(&after_mouse_resolver);
    const expected_mouse_scroll = after_mouse_body.restoreSelectionViewportAnchor(mouse_anchor);
    try std.testing.expectEqual(mouse_anchor.raw_presentation_scroll, expected_mouse_scroll);
    try std.testing.expectEqual(expected_mouse_scroll, app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 0), app.shell_effects_state.clipboard_copies.count());
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

    changesNavigation(&app).selectFileAbsolute(0);
    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.changes.viewer.sidebar_width) + 1;
    const diff_msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_down)) orelse return error.ExpectedDiffWheelMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(changes_page.Focus.diff, app.pages.changes.viewer.focus);
    try std.testing.expect(app.pages.changes.viewer.diff_scroll > 0);
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

test "help overlay wheel scrolls help and ignores clicks" {
    var app: App = .{
        .pages = .{ .changes = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .help },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedHelpWheelMessage;
    try std.testing.expectEqual(App.Msg.help_scroll_down, msg);
    try app.update(msg, undefined);
    try std.testing.expect(app.overlay.help_scroll > 0);

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "push error overlay wheel scrolls details and ignores clicks" {
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

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedPushErrorWheelMessage;
    try std.testing.expectEqual(App.Msg.push_error_scroll_down, msg);
    try app.update(msg, undefined);
    try std.testing.expect(app.overlay.push_error_scroll > 0);

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
    const page_ids = [_]page.Id{ .changes, .repository, .review };

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
            .review => &app.pages.review.status,
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
