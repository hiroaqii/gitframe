//! Pure root-shell input routing and bounded overlay scrolling.
//!
//! The root composes short-lived page and layout snapshots. `View` translates
//! terminal events directly into the concrete root message vocabulary without
//! retaining application state or importing `app.zig`. Overlay scrolling is a
//! separate synchronous controller over the root-owned overlay value.

const std = @import("std");
const chasen = @import("chasen");

const app_input = @import("input.zig");
const app_message = @import("message.zig");
const app_prompt = @import("prompt.zig");
const app_shell_layout = @import("shell_layout.zig");
const app_state = @import("state.zig");
const app_view = @import("view.zig");
const diff_surface = @import("diff_surface.zig");
const drag_auto_scroll = @import("drag_auto_scroll.zig");
const diff_selection = @import("../diff/selection.zig");
const keymap = @import("keymap");
const loaded_diff = @import("../loaded_diff.zig");
const page = @import("page.zig");
const repository_page = @import("pages/repository.zig");
const repository_input = @import("pages/repository/input.zig");
const repository_layout = @import("pages/repository/layout.zig");
const history_view = @import("pages/history/view.zig");
const changes_layout = @import("pages/changes/layout.zig");
const changes_message = @import("pages/changes/message.zig");

const MousePane = enum {
    sidebar,
    diff,
};

const ActiveDiffSelectionOwner = union(enum) {
    changes: *const diff_selection.Owner,
    history: *const diff_selection.Owner,
    compare: *const diff_selection.Owner,

    fn active(self: ActiveDiffSelectionOwner) bool {
        return switch (self) {
            inline .changes, .history, .compare => |owner| owner.activeMouseSelection(),
        };
    }
};

const MousePoint = diff_surface.MousePoint;
const sidebar_header_rows: u16 = changes_layout.sidebar_header_rows;

pub const ChangesContext = struct {
    key: app_input.ChangesContext,
    selection_owner: *const diff_selection.Owner,
    loaded: ?*const loaded_diff.LoadedDiff,
    selected_node: usize,
    sidebar_hidden: bool,
    sidebar_width: ?u16,
};

pub const CompareContext = struct {
    key: app_input.CompareContext,
    selection_owner: *const diff_selection.Owner,
    loaded: ?*const loaded_diff.LoadedDiff,
    selected_node: usize,
    sidebar_hidden: bool,
    sidebar_width: ?u16,
};

pub const RepositoryContext = struct {
    key: repository_input.Context,
    page_state: *const repository_page.RepositoryPageState,
};

pub const HistoryContext = struct {
    key: app_input.HistoryContext = .{},
    picker_layout: ?history_view.PickerLayout = null,
    picker_visible_start: usize = 0,
    picker_visible_end: usize = 0,
    selection_owner: ?*const diff_selection.Owner = null,
    loaded: ?*const loaded_diff.LoadedDiff = null,
    selected_node: usize = 0,
    sidebar_hidden: bool = false,
    sidebar_width: ?u16 = null,
};

pub const View = struct {
    active_page: page.Id,
    changes: ChangesContext,
    compare: CompareContext,
    repository: RepositoryContext,
    history: HistoryContext = .{},
    create_stash: ?*const @import("stash.zig").Create = null,
    stash_catalog: ?*const @import("stash.zig").Catalog = null,
    commit_panel_mode: bool,
    repo_picker_mode: bool,
    repo_picker_input_mode: app_prompt.RepoPickerInputMode,
    branch_switch_query_mode: bool = false,
    branch_switch_query_len: usize = 0,
    branch_switch_pending: bool = false,
    remote_action_cancelable: bool = false,
    remote_error_interactive: bool = false,
    command_line_active: bool = false,
    repository_command_available: bool = false,
    keymap: keymap.Effective,
    overlay: *const app_state.OverlayState,
    layout: app_shell_layout.Layout,
    footer_status_target: ?app_view.FooterStatusTarget = null,

    pub fn handleEvent(self: View, event: chasen.Event) ?app_message.Msg {
        return switch (event) {
            .mouse => |mouse| self.mouseToMsg(mouse),
            .focus_out => .focus_lost,
            else => app_input.eventToMsg(self.keyContext(), event),
        };
    }

    fn keyContext(self: View) app_input.KeyContext {
        return .{
            .active_page = self.active_page,
            .changes = self.changes.key,
            .compare = self.compare.key,
            .repository = self.repository.key,
            .history = self.history.key,
            .create_stash = self.create_stash,
            .stash_catalog = self.stash_catalog,
            .commit_panel_mode = self.commit_panel_mode,
            .repo_picker_mode = self.repo_picker_mode,
            .repo_picker_input_mode = self.repo_picker_input_mode,
            .help_mode = self.overlay.isHelp(),
            .discard_confirmation_mode = self.overlay.isDiscardFile(),
            .amend_confirmation_mode = self.overlay.isAmendCommit(),
            .push_confirmation_mode = self.overlay.isPushBranch(),
            .pull_confirmation_mode = self.overlay.isPullBranch(),
            .branch_switch_mode = self.overlay.isSwitchBranch(),
            .branch_switch_query_mode = self.branch_switch_query_mode,
            .branch_switch_query_len = self.branch_switch_query_len,
            .branch_switch_pending = self.branch_switch_pending,
            .remote_error_mode = self.overlay.isRemoteError(),
            .remote_error_interactive = self.remote_error_interactive,
            .remote_action_cancelable = self.remote_action_cancelable,
            .active_selection_gesture = if (self.activeDiffSelectionOwner()) |selection| selection.active() else self.active_page == .repository and self.repository.page_state.activeMouseOwner(),
            .command_line_active = self.command_line_active,
            .repository_command_available = self.repository_command_available,
            .keymap = self.keymap,
        };
    }

    fn mouseToMsg(self: View, mouse: anytype) ?app_message.Msg {
        if (self.command_line_active) return null;
        if (self.activeDiffSelectionOwner()) |selection| {
            if (selection.active()) switch (selection) {
                .changes => switch (mouse.type) {
                    .drag => return .{ .mouse_selection_drag = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .changes = self.bodyMousePoint(mouse) },
                    } },
                    .release => return .{ .mouse_selection_release = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .changes = self.bodyMousePoint(mouse) },
                    } },
                    else => {},
                },
                .compare => switch (mouse.type) {
                    .drag => return .{ .mouse_selection_drag = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .compare = self.bodyMousePoint(mouse) },
                    } },
                    .release => return .{ .mouse_selection_release = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .compare = self.bodyMousePoint(mouse) },
                    } },
                    else => {},
                },
                .history => switch (mouse.type) {
                    .drag => return .{ .mouse_selection_drag = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .history = self.bodyMousePoint(mouse) },
                    } },
                    .release => return .{ .mouse_selection_release = .{
                        .pointer = self.bodyPointerSample(mouse),
                        .target = .{ .history = self.bodyMousePoint(mouse) },
                    } },
                    else => {},
                },
            };
        }

        if (self.repository.page_state.activeMouseOwner()) {
            const body_point: ?repository_layout.BodyPoint = if (self.bodyMousePoint(mouse)) |point|
                .{ .col = point.col, .row = point.row }
            else
                null;
            const source_point = repository_layout.sourceGesturePoint(
                body_point,
                self.layout.bodySize(),
                self.repository.page_state.viewer.tree_width,
                self.repository.page_state.viewer.tree_hidden,
            );
            switch (mouse.type) {
                .drag => return .{ .mouse_selection_drag = .{
                    .pointer = self.bodyPointerSample(mouse),
                    .target = .{ .repository = source_point },
                } },
                .release => return .{ .mouse_selection_release = .{
                    .pointer = self.bodyPointerSample(mouse),
                    .target = .{ .repository = source_point },
                } },
                else => {},
            }
        }

        if ((self.active_page == .changes and (self.changes.key.search_mode or self.changes.key.file_search_mode)) or
            (self.active_page == .compare and (self.compare.key.common.search_mode or self.compare.key.common.file_search_mode or
                self.compare.key.base_picker_open)) or
            (self.active_page == .history and (self.history.key.common.search_mode or self.history.key.common.file_search_mode)) or
            (self.active_page == .repository and (self.repository.key.source_search_mode or self.repository.key.file_search_mode)) or
            self.commit_panel_mode or self.repo_picker_mode) return null;
        if (mouse.type != .press) return null;

        switch (self.overlay.mouseMode()) {
            .passthrough => {},
            .block => return null,
            .scroll_help => return switch (mouse.button) {
                .wheel_up => .help_scroll_up,
                .wheel_down => .help_scroll_down,
                else => null,
            },
            .scroll_remote_error => return switch (mouse.button) {
                .wheel_up => .remote_error_scroll_up,
                .wheel_down => .remote_error_scroll_down,
                else => null,
            },
        }

        if (mouse.button == .left) {
            if (self.footer_status_target) |target| {
                if (self.layout.terminalToFooter(mouse.col, mouse.row)) |point| {
                    if (target.contains(point.col)) return .copy_footer_status;
                }
            }
            if (self.layout.page_bar) |bar| {
                if (self.layout.terminalToContent(mouse.col, mouse.row)) |point| {
                    if (point.row == app_shell_layout.page_bar_label_row) {
                        const compact = self.layout.body.height == 0 or self.layout.footer.height == 0;
                        const target = if (compact)
                            if (point.col >= 1 and point.col < @min(bar.width, self.active_page.label().len + 3)) self.active_page else null
                        else
                            page.tabAtColumn(bar.width, point.col);
                        if (target) |id| return .{ .switch_page = id };
                        return null;
                    }
                }
            }
        }

        // Page-bar presses above still reach the common blocker and explain
        // why the switch was rejected. Inside the Repository body, a second
        // press or wheel event cannot replace the active gesture implicitly.
        if (self.repository.page_state.activeMouseOwner()) return null;
        if (self.active_page == .repository) {
            const point = self.layout.terminalToBody(mouse.col, mouse.row) orelse return null;
            const button: repository_page.MouseButton = switch (mouse.button) {
                .left => .left,
                .wheel_up => .wheel_up,
                .wheel_down => .wheel_down,
                else => return null,
            };
            const repository_msg = self.repository.page_state.mouseToMsg(
                .{ .col = point.col, .row = point.row },
                button,
                self.layout.bodySize(),
            ) orelse return null;
            return .{ .repository = repository_msg };
        }

        if (self.active_page == .compare) {
            const pane = self.committedDiffMousePane(self.compare, mouse) orelse return null;
            return switch (mouse.button) {
                .left => switch (pane) {
                    .sidebar => .{ .compare = .{ .common = .{ .shared = self.committedDiffSidebarClickToMsg(self.compare, mouse) } } },
                    .diff => .{ .compare = .{ .common = .{ .shared = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } } } },
                },
                .wheel_up => .{ .compare = .{ .common = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up } } },
                .wheel_down => .{ .compare = .{ .common = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down } } },
                .wheel_left => if (pane == .diff) .{ .compare = .{ .common = .{ .shared = .mouse_diff_wheel_left } } } else null,
                .wheel_right => if (pane == .diff) .{ .compare = .{ .common = .{ .shared = .mouse_diff_wheel_right } } } else null,
                else => null,
            };
        }
        if (self.active_page == .history and self.history.key.diff_view) {
            const pane = self.committedDiffMousePane(self.history, mouse) orelse return null;
            return switch (mouse.button) {
                .left => switch (pane) {
                    .sidebar => .{ .history = .{ .common = .{ .shared = self.committedDiffSidebarClickToMsg(self.history, mouse) } } },
                    .diff => .{ .history = .{ .common = .{ .shared = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } } } },
                },
                .wheel_up => .{ .history = .{ .common = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up } } },
                .wheel_down => .{ .history = .{ .common = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down } } },
                .wheel_left => if (pane == .diff) .{ .history = .{ .common = .{ .shared = .mouse_diff_wheel_left } } } else null,
                .wheel_right => if (pane == .diff) .{ .history = .{ .common = .{ .shared = .mouse_diff_wheel_right } } } else null,
                else => null,
            };
        }
        if (self.active_page == .history) {
            const point = self.bodyMousePoint(mouse) orelse return null;
            if (mouse.button == .left) {
                const picker_layout = self.history.picker_layout orelse return null;
                const focus = picker_layout.focusAt(point) orelse return null;
                if (focus == .history and !self.history.key.loading and self.history.key.picker_ready) {
                    if (picker_layout.historyIndexAt(
                        point,
                        self.history.picker_visible_start,
                        self.history.picker_visible_end,
                    )) |index| return .{ .history = .{ .select_row = index } };
                }
                return .{ .history = .{ .focus_pane = focus } };
            }
            return switch (self.history.key.focus) {
                .history => if (self.history.key.loading or !self.history.key.picker_ready)
                    null
                else switch (mouse.button) {
                    .wheel_up => if (self.history.key.picker_can_move_previous) .{ .history = .move_previous } else null,
                    .wheel_down => if (self.history.key.picker_can_move_next) .{ .history = .move_next } else null,
                    else => null,
                },
                .commit_detail => switch (mouse.button) {
                    .wheel_up => .{ .history = .{ .move_detail = .row_previous } },
                    .wheel_down => .{ .history = .{ .move_detail = .row_next } },
                    else => null,
                },
                .changed_files => switch (mouse.button) {
                    .wheel_up => .{ .history = .{ .move_files = .row_previous } },
                    .wheel_down => .{ .history = .{ .move_files = .row_next } },
                    else => null,
                },
            };
        }
        if (self.active_page != .changes) return null;

        const pane = self.changesMousePane(mouse) orelse return null;
        return switch (mouse.button) {
            .left => switch (pane) {
                .sidebar => .{ .changes = self.changesSidebarClickToMsg(mouse) },
                .diff => .{ .changes = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } },
            },
            .wheel_up => .{ .changes = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up },
            .wheel_down => .{ .changes = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down },
            .wheel_left => if (pane == .diff) .{ .changes = .mouse_diff_wheel_left } else null,
            .wheel_right => if (pane == .diff) .{ .changes = .mouse_diff_wheel_right } else null,
            else => null,
        };
    }

    fn activeDiffSelectionOwner(self: View) ?ActiveDiffSelectionOwner {
        return switch (self.active_page) {
            .changes => .{ .changes = self.changes.selection_owner },
            .history => .{ .history = self.history.selection_owner orelse return null },
            .compare => .{ .compare = self.compare.selection_owner },
            .repository, .config => null,
        };
    }

    fn committedDiffMousePane(self: View, context: anytype, mouse: anytype) ?MousePane {
        _ = context.loaded orelse return null;
        const point = self.bodyMousePoint(mouse) orelse return null;
        if (context.sidebar_hidden) return .diff;
        const sidebar_width = changes_layout.sidebarWidth(
            self.layout.content.width,
            context.sidebar_width,
        );
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn committedDiffSidebarClickToMsg(self: View, context: anytype, mouse: anytype) diff_surface.message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.layout.body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;
        const loaded = context.loaded orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(
            context.selected_node,
            visible_rows,
            body_row,
        ) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    fn changesMousePane(self: View, mouse: anytype) ?MousePane {
        _ = self.changes.loaded orelse return null;
        const point = self.bodyMousePoint(mouse) orelse return null;
        if (self.changes.sidebar_hidden) return .diff;
        const sidebar_width = changes_layout.sidebarWidth(
            self.layout.content.width,
            self.changes.sidebar_width,
        );
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn changesSidebarClickToMsg(self: View, mouse: anytype) changes_message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.layout.body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;
        const loaded = self.changes.loaded orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(
            self.changes.selected_node,
            visible_rows,
            body_row,
        ) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    /// Single termination boundary for every mouse-selection lifetime. Update
    /// resolves a deferred background source result after this becomes idle;
    /// deinit discards that result explicitly.
    fn bodyMousePoint(self: View, mouse: anytype) ?MousePoint {
        const point = self.layout.terminalToBody(mouse.col, mouse.row) orelse return null;
        return .{ .col = point.col, .row = point.row };
    }

    fn bodyPointerSample(self: View, mouse: anytype) drag_auto_scroll.PointerSample {
        return .{
            .col = @as(i32, mouse.col) - @as(i32, self.layout.body.col),
            .row = @as(i32, mouse.row) - @as(i32, self.layout.body.row),
        };
    }
};

pub const OverlayScrollController = struct {
    overlay: *app_state.OverlayState,
    content_size: chasen.Size,
    help_page: page.Id,
    remote_error_message: ?[]const u8,

    pub fn scrollHelp(self: OverlayScrollController, delta: isize) bool {
        const previous = self.overlay.help_scroll;
        self.overlay.help_scroll = applySignedScroll(self.overlay.help_scroll, delta);
        self.clampHelp();
        return previous != self.overlay.help_scroll;
    }

    pub fn pageHelp(self: OverlayScrollController, pages: isize) void {
        const rows = @max(@as(usize, app_view.helpVisibleRows(self.content_size, self.help_page)), 1);
        _ = self.scrollHelp(pageDelta(rows, pages));
    }

    pub fn clampHelp(self: OverlayScrollController) void {
        self.overlay.help_scroll = @min(
            self.overlay.help_scroll,
            app_view.helpMaxScroll(self.content_size, self.help_page),
        );
    }

    pub fn scrollRemoteError(self: OverlayScrollController, delta: isize) bool {
        const previous = self.overlay.remote_error_scroll;
        self.overlay.remote_error_scroll = applySignedScroll(self.overlay.remote_error_scroll, delta);
        self.clampRemoteError();
        return previous != self.overlay.remote_error_scroll;
    }

    pub fn pageRemoteError(self: OverlayScrollController, pages: isize) void {
        const rows = @max(@as(usize, app_view.remoteErrorVisibleRows(
            self.content_size,
            self.remote_error_message,
        )), 1);
        _ = self.scrollRemoteError(pageDelta(rows, pages));
    }

    pub fn clampRemoteError(self: OverlayScrollController) void {
        self.overlay.remote_error_scroll = @min(
            self.overlay.remote_error_scroll,
            app_view.remoteErrorMaxScroll(self.content_size, self.remote_error_message),
        );
    }
};

fn pageDelta(rows: usize, pages: isize) isize {
    return if (pages < 0)
        -@as(isize, @intCast(rows))
    else
        @as(isize, @intCast(rows));
}

fn applySignedScroll(current: usize, delta: isize) usize {
    if (delta < 0) {
        const amount: usize = @intCast(-(delta + 1));
        return current -| (amount + 1);
    }
    return current +| @as(usize, @intCast(delta));
}

test "Repository Help scrolling stays bounded" {
    const size: chasen.Size = .{ .width = 80, .height = 12 };
    const visible_rows: usize = app_view.helpVisibleRows(size, .repository);
    const max_scroll = app_view.helpMaxScroll(size, .repository);
    try std.testing.expect(visible_rows > 0);
    try std.testing.expect(max_scroll > visible_rows);

    var overlay: app_state.OverlayState = .{};
    overlay.openHelpForPage(.repository);
    const controller: OverlayScrollController = .{
        .overlay = &overlay,
        .content_size = size,
        .help_page = .repository,
        .remote_error_message = null,
    };

    _ = controller.scrollHelp(1);
    try std.testing.expectEqual(@as(usize, 1), overlay.help_scroll);
    controller.pageHelp(1);
    try std.testing.expectEqual(@min(1 + visible_rows, max_scroll), overlay.help_scroll);
    _ = controller.scrollHelp(std.math.maxInt(isize));
    try std.testing.expectEqual(max_scroll, overlay.help_scroll);
    controller.pageHelp(-1);
    try std.testing.expectEqual(max_scroll -| visible_rows, overlay.help_scroll);
    _ = controller.scrollHelp(-std.math.maxInt(isize));
    try std.testing.expectEqual(@as(usize, 0), overlay.help_scroll);
}

test "History routes committed diff and picker mouse input through the shell" {
    var overlay: app_state.OverlayState = .{};
    var selection_owner: diff_selection.Owner = .none;
    var repository_state: repository_page.RepositoryPageState = .{};
    var loaded: loaded_diff.LoadedDiff = undefined;
    const layout = app_shell_layout.compute(.{ .width = 80, .height = 24 }, .{ .page_bar_visible = true });
    const view: View = .{
        .active_page = .history,
        .changes = .{
            .key = .{},
            .selection_owner = &selection_owner,
            .loaded = null,
            .selected_node = 0,
            .sidebar_hidden = false,
            .sidebar_width = null,
        },
        .compare = .{
            .key = .{},
            .selection_owner = &selection_owner,
            .loaded = null,
            .selected_node = 0,
            .sidebar_hidden = false,
            .sidebar_width = null,
        },
        .repository = .{ .key = .{}, .page_state = &repository_state },
        .history = .{
            .key = .{ .diff_view = true },
            .selection_owner = &selection_owner,
            .loaded = &loaded,
            .selected_node = 0,
            .sidebar_hidden = true,
            .sidebar_width = null,
        },
        .commit_panel_mode = false,
        .repo_picker_mode = false,
        .repo_picker_input_mode = .list,
        .keymap = .{},
        .overlay = &overlay,
        .layout = layout,
    };
    const point: MousePoint = .{ .col = 10, .row = 5 };
    const terminal_col: i16 = @intCast(layout.body.col + point.col);
    const terminal_row: i16 = @intCast(layout.body.row + point.row);
    try std.testing.expectEqual(
        app_message.Msg{ .history = .{ .common = .{ .shared = .{ .mouse_diff_press = point } } } },
        view.handleEvent(.{ .mouse = .{
            .col = terminal_col,
            .row = terminal_row,
            .button = .left,
            .mods = .{},
            .type = .press,
        } }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .history = .{ .common = .{ .shared = .mouse_diff_wheel_down } } },
        view.handleEvent(.{ .mouse = .{
            .col = terminal_col,
            .row = terminal_row,
            .button = .wheel_down,
            .mods = .{},
            .type = .press,
        } }).?,
    );

    selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "file.txt" } },
        .content = .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .anchor_cell = .{ .col = point.col, .row = point.row },
    } };
    const drag = view.handleEvent(.{ .mouse = .{
        .col = terminal_col,
        .row = terminal_row,
        .button = .left,
        .mods = .{},
        .type = .drag,
    } }).?;
    switch (drag) {
        .mouse_selection_drag => |continuation| switch (continuation.target) {
            .history => |history_point| try std.testing.expectEqual(point, history_point.?),
            else => return error.ExpectedHistoryDrag,
        },
        else => return error.ExpectedHistoryDrag,
    }
    const release = view.handleEvent(.{ .mouse = .{
        .col = terminal_col,
        .row = terminal_row,
        .button = .left,
        .mods = .{},
        .type = .release,
    } }).?;
    switch (release) {
        .mouse_selection_release => |continuation| switch (continuation.target) {
            .history => |history_point| try std.testing.expectEqual(point, history_point.?),
            else => return error.ExpectedHistoryRelease,
        },
        else => return error.ExpectedHistoryRelease,
    }

    selection_owner = .none;
    var picker_view = view;
    picker_view.history.key = .{
        .picker_ready = true,
        .picker_can_move_next = true,
    };
    picker_view.history.loaded = null;
    const picker_layout = history_view.pickerLayout(layout.bodySize(), .{});
    picker_view.history.picker_layout = picker_layout;
    picker_view.history.picker_visible_start = 4;
    picker_view.history.picker_visible_end = 7;
    for ([_]struct { point: MousePoint, expected: app_message.Msg }{
        .{
            .point = .{ .col = picker_layout.history.col, .row = picker_layout.history.row },
            .expected = .{ .history = .{ .focus_pane = .history } },
        },
        .{
            .point = .{ .col = picker_layout.detail.col, .row = picker_layout.detail.row },
            .expected = .{ .history = .{ .focus_pane = .commit_detail } },
        },
        .{
            .point = .{ .col = picker_layout.files.col, .row = picker_layout.files.row },
            .expected = .{ .history = .{ .focus_pane = .changed_files } },
        },
    }) |case| {
        try std.testing.expectEqual(case.expected, picker_view.handleEvent(.{ .mouse = .{
            .col = @intCast(layout.body.col + case.point.col),
            .row = @intCast(layout.body.row + case.point.row),
            .button = .left,
            .mods = .{},
            .type = .press,
        } }).?);
    }
    for ([_]struct { row: u16, expected: app_message.Msg }{
        .{ .row = 1, .expected = .{ .history = .{ .focus_pane = .history } } },
        .{ .row = 2, .expected = .{ .history = .{ .select_row = 4 } } },
        .{ .row = 4, .expected = .{ .history = .{ .select_row = 6 } } },
        .{ .row = 5, .expected = .{ .history = .{ .focus_pane = .history } } },
    }) |case| {
        try std.testing.expectEqual(case.expected, picker_view.handleEvent(.{ .mouse = .{
            .col = @intCast(layout.body.col + picker_layout.history.col),
            .row = @intCast(layout.body.row + picker_layout.history.row + case.row),
            .button = .left,
            .mods = .{},
            .type = .press,
        } }).?);
    }
    for ([_]MousePoint{
        .{ .col = picker_layout.outer_divider.col, .row = picker_layout.outer_divider.row },
        .{ .col = picker_layout.inner_divider.col, .row = picker_layout.inner_divider.row },
    }) |divider_point| {
        try std.testing.expect(picker_view.handleEvent(.{ .mouse = .{
            .col = @intCast(layout.body.col + divider_point.col),
            .row = @intCast(layout.body.row + divider_point.row),
            .button = .left,
            .mods = .{},
            .type = .press,
        } }) == null);
    }
    const picker_wheel_up = chasen.Event{ .mouse = .{
        .col = terminal_col,
        .row = terminal_row,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    } };
    const picker_wheel_down = chasen.Event{ .mouse = .{
        .col = terminal_col,
        .row = terminal_row,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } };
    try std.testing.expect(picker_view.handleEvent(picker_wheel_up) == null);
    try std.testing.expectEqual(
        app_message.Msg{ .history = .move_next },
        picker_view.handleEvent(picker_wheel_down).?,
    );

    picker_view.history.key.picker_can_move_previous = true;
    picker_view.history.key.picker_can_move_next = false;
    try std.testing.expectEqual(
        app_message.Msg{ .history = .move_previous },
        picker_view.handleEvent(picker_wheel_up).?,
    );
    try std.testing.expect(picker_view.handleEvent(picker_wheel_down) == null);

    var detail_view = picker_view;
    detail_view.history.key.focus = .commit_detail;
    try std.testing.expectEqual(
        app_message.Msg{ .history = .{ .move_detail = .row_next } },
        detail_view.handleEvent(picker_wheel_down).?,
    );
    detail_view.history.key.focus = .changed_files;
    try std.testing.expectEqual(
        app_message.Msg{ .history = .{ .move_files = .row_previous } },
        detail_view.handleEvent(picker_wheel_up).?,
    );
    const compare_tab = page.tab(.compare);
    try std.testing.expectEqual(
        app_message.Msg{ .switch_page = .compare },
        detail_view.handleEvent(.{ .mouse = .{
            .col = @intCast(layout.content.col + compare_tab.col),
            .row = @intCast(layout.content.row + app_shell_layout.page_bar_label_row),
            .button = .left,
            .mods = .{},
            .type = .press,
        } }).?,
    );
}
