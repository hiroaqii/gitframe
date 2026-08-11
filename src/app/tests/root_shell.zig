//! Root-shell input and lifecycle integration tests.

const std = @import("std");
const chasen = @import("chasen");
const app_mod = @import("../../app.zig");
const app_test_support = @import("../test_support.zig");
const app_load = @import("../load.zig");
const app_message = @import("../message.zig");
const app_shell_layout = @import("../shell_layout.zig");
const app_state = @import("../state.zig");
const app_view = @import("../view.zig");
const page = @import("../page.zig");
const review_page = @import("../pages/review.zig");
const review_navigation = @import("../pages/review/navigation.zig");
const review_reload = @import("../pages/review/reload.zig");
const review_authority = @import("../diff_surface/authority.zig");
const context = @import("../../context.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const git_status = @import("../../git/status.zig");
const repo_discovery = @import("../../repo/discovery.zig");
const review_session = @import("../../review/session.zig");

const App = app_mod.App;
const OverlayKind = app_state.OverlayKind;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const sidebar_header_rows: u16 = @import("../pages/review/layout.zig").sidebar_header_rows;

fn shellLayout(app: *const App) app_shell_layout.Layout {
    return app_shell_layout.compute(app.terminal_size, .{ .page_bar_visible = true });
}

fn layoutSize(app: *const App) chasen.Size {
    return app_shell_layout.contentSize(app.terminal_size);
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return @import("../pages/review/layout.zig").sidebarWidth(total_width, preferred_width);
}

fn terminalBodyHeight(terminal_height: u16) u16 {
    return app_shell_layout.bodyHeight(terminal_height);
}

fn reviewNavigation(app: *App) review_navigation.Controller {
    const size = shellLayout(app).bodySize();
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

fn activateReview(app: *App) u64 {
    const source_member: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        switch (app.pages.review.load.state) {
            .loaded, .empty => .immutable,
            .loading => .pending,
            .failed => .failed,
            .idle => .pending,
        }
    else
        .pending;
    const auxiliary: review_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(app.config.source) and app.repo_session.view().activeRoot() != null) .pending else .unavailable;
    return app.pages.review.activation.activate(app.repo_session.view().epoch(), source_member, auxiliary, auxiliary);
}

test "diff mouse selection owner is resolved from the active page surface" {
    var app: App = .{ .terminal_size = .{ .width = 80, .height = 20 } };
    app.pages.review.selection_owner = .{ .diff_header = .{
        .identity = .{ .kind = .loaded_file, .path_key = "a" },
    } };

    const drag = app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) orelse return error.ExpectedDiffSelectionOwner;
    switch (drag) {
        .review => |review_msg| switch (review_msg) {
            .mouse_diff_drag => {},
            else => return error.ExpectedReviewDiffDrag,
        },
        else => return error.ExpectedReviewDiffDrag,
    }

    app.active_page = .repository;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) == null);
}

test "terminal resize cancels live drag before geometry and retains completed selection" {
    const allocator = std.testing.allocator;
    const review_selection = @import("../diff_surface/selection.zig");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 20 },
    };
    defer reviewReload(&app).clearLoadedDiff(allocator);

    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    };
    app.pages.review.completed_selection = try review_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = review_selection.SourceBasis.init(.unstaged),
        .source_session_revision = app.pages.review.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    const retained_token = app.pages.review.completed_selection.?.token;
    app.pages.review.selection_owner = .{ .diff = selection };
    app.pages.compare.selection_owner = .{ .diff = selection };

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, undefined);

    try std.testing.expect(app.pages.review.selection_owner == .none);
    try std.testing.expect(app.pages.compare.selection_owner == .none);
    try std.testing.expect(app.pages.review.completed_selection != null);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expectEqual(chasen.Size{ .width = 120, .height = 30 }, app.terminal_size);
}

test "help overlay opens and closes before normal shortcuts" {
    var app: App = .{};

    const open_msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedOpenHelp;
    try app.update(open_msg, undefined);
    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);

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
        .pages = .{ .review = .{
            .search = .{ .mode = true },
        } },
    };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedPromptInput;
    try app.update(msg, undefined);

    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expectEqualStrings("?", app.pages.review.search.input.slice());
}

test "mouse click focuses sidebar and diff panes" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_event = app_test_support.mouseEvent(content.col + 1, content.row + 2, .left);
    const sidebar_msg = app.handleEvent(sidebar_event) orelse return error.ExpectedSidebarMouseMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);

    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.review.viewer.sidebar_width) + 1;
    const diff_event = app_test_support.mouseEvent(diff_col, content.row + 2, .left);
    const diff_msg = app.handleEvent(diff_event) orelse return error.ExpectedDiffMouseMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "mouse click selects sidebar file rows" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "mouse click toggles sidebar directory rows" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff, .selected_node = 1 },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer reviewReload(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarDirectoryClickMessage;
    try app.update(msg, undefined);

    const loaded = reviewNavigation(&app).activeLoadedDiff().?;
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
}

test "mouse click on sidebar header or blank body focuses only" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const header_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + app_shell_layout.page_bar_rows, .left)) orelse return error.ExpectedSidebarHeaderClickMessage;
    try app.update(header_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);

    app.pages.review.viewer.focus = .diff;
    const blank_row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 2;
    const blank_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, blank_row, .left)) orelse return error.ExpectedSidebarBlankClickMessage;
    try app.update(blank_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
}

test "mouse click uses filtered sidebar projection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    loaded.reviewed_files = try arena.allocator().alloc(bool, loaded.document.files.len);
    @memset(loaded.reviewed_files, false);
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .deleted);

    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{ .focus = .diff, .selected_node = 0 },
            .review_display = .{ .changed_file_filter = .deleted },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer reviewReload(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedFilteredSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "mouse wheel scrolls the pane under the pointer" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedSidebarWheelMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);

    reviewNavigation(&app).selectFileAbsolute(0);
    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.review.viewer.sidebar_width) + 1;
    const diff_msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_down)) orelse return error.ExpectedDiffWheelMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expect(app.pages.review.viewer.diff_scroll > 0);
}

test "mouse uses full body as diff pane while sidebar is hidden" {
    var app: App = .{
        .pages = .{ .review = .{
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
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "help overlay wheel scrolls help and ignores clicks" {
    var app: App = .{
        .pages = .{ .review = .{
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
        .pages = .{ .review = .{
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
        .pages = .{ .review = .{
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
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
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
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .focus = .sidebar,
                .display_mode = .unified,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const diff_col = content.col + sidebarWidth(layoutSize(&app).width, app.pages.review.viewer.sidebar_width) + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_right)) orelse return error.ExpectedHorizontalWheelMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll > 0);
}

test "mouse events are ignored outside body and prompt modes" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(-1, 1, .left)) == null);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const footer_row: i16 = @intCast(content.row + terminalBodyHeight(layoutSize(&app).height));
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, footer_row, .left)) == null);

    app.pages.review.search.mode = true;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 1, .left)) == null);
}

test "mouse release and motion events are ignored" {
    var app: App = .{
        .pages = .{ .review = .{
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
        .pages = .{ .review = .{ .search = .{ .mode = true } } },
    };
    @memset(&app.pages.review.search.input.buffer, 'x');
    app.pages.review.search.input.len = app.pages.review.search.input.buffer.len;
    app.pages.review.search.input.cursor = app.pages.review.search.input.buffer.len;

    try app.update(.{ .review = .{ .search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.review.status.text());

    app.status.clear();
    try app.update(.{ .review = .{ .search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.review.status.text());
}

test "file search overflow reports query status for insert and paste" {
    var app: App = .{
        .pages = .{ .review = .{ .file_search = .{ .mode = true } } },
    };
    @memset(&app.pages.review.file_search.input.buffer, 'x');
    app.pages.review.file_search.input.len = app.pages.review.file_search.input.buffer.len;
    app.pages.review.file_search.input.cursor = app.pages.review.file_search.input.buffer.len;

    try app.update(.{ .review = .{ .file_search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.review.status.text());

    app.status.clear();
    try app.update(.{ .review = .{ .file_search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.review.status.text());
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
    try std.testing.expectEqual(App.Msg{ .switch_page = .review }, app.handleEvent(app_test_support.mouseEvent(
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

test "direct nested Review message uses the same update owner as keyboard input" {
    var direct: App = .{ .allocator = std.testing.allocator };
    var keyboard: App = .{ .allocator = std.testing.allocator };
    var direct_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var keyboard_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try direct.update(.{ .review = .toggle_focus }, &direct_ctx);
    const keyboard_msg = keyboard.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.tab } }) orelse return error.ExpectedReviewMessage;
    try std.testing.expectEqual(App.Msg{ .review = .toggle_focus }, keyboard_msg);
    try keyboard.update(keyboard_msg, &keyboard_ctx);

    try std.testing.expectEqual(review_page.Focus.diff, direct.pages.review.viewer.focus);
    try std.testing.expectEqual(direct.pages.review.viewer.focus, keyboard.pages.review.viewer.focus);
}

test "normal and help commit keys use the same nested Review adapter" {
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
    help.overlay.openHelpForPage(.review);
    var normal_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var help_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const normal_msg = normal.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedReviewMessage;
    const help_msg = help.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedReviewMessage;
    try std.testing.expectEqual(App.Msg{ .review = .enter_commit_panel }, normal_msg);
    try std.testing.expectEqual(normal_msg, help_msg);

    try normal.update(normal_msg, &normal_ctx);
    try help.update(help_msg, &help_ctx);
    try std.testing.expect(normal.local_workflow.commit_panel.is_open);
    try std.testing.expect(help.local_workflow.commit_panel.is_open);
    try std.testing.expect(!help.overlay.isHelp());
}

test "review session q writes structured canceled output before quitting" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .review_mode = true },
        .review_output = &output,
    };
    _ = app.pages.review.activation.activate(0, .fresh, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'q' } }) orelse return error.ExpectedReviewCancel;
    try std.testing.expectEqual(App.Msg{ .review = .finish_review_canceled }, msg);
    try app.update(msg, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 130), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"canceled\"") != null);
}

test "focus loss terminates selection without a deferred result" {
    var app: App = .{
        .pages = .{ .review = .{
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .config = .{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } },
    };
    _ = activateReview(&app);
    app.pages.review.auto_reload = .init(.inherit, .{}, app.config.source);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try std.testing.expectEqual(App.Msg.focus_lost, app.handleEvent(.focus_out).?);
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.review.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.review.deferred_source_apply == null);

    try app.update(.auto_reload_tick, &ctx);
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const cycle_id = task.background_cycle_id.?;
    const generation = task.generation;
    DiffLoadTask.destroy(task, std.testing.allocator);
    _ = app.pages.review.load.clearPendingIfCurrent(.{ .diff_load = generation });
    reviewReload(&app).clearPendingReloadIfGeneration(std.testing.allocator, generation);
    app.pages.review.auto_reload.finishMember(cycle_id, .source);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}
