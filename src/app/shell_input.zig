//! Pure root-shell input routing and bounded overlay scrolling.
//!
//! The root composes short-lived page and layout snapshots. `View` translates
//! terminal events directly into the concrete root message vocabulary without
//! retaining application state or importing `app.zig`. Overlay scrolling is a
//! separate synchronous controller over the root-owned overlay value.

const chasen = @import("chasen");

const app_input = @import("input.zig");
const app_message = @import("message.zig");
const app_prompt = @import("prompt.zig");
const app_shell_layout = @import("shell_layout.zig");
const app_state = @import("state.zig");
const app_view = @import("view.zig");
const diff_surface = @import("diff_surface.zig");
const diff_selection = @import("../diff/selection.zig");
const keymap = @import("keymap");
const loaded_diff = @import("../loaded_diff.zig");
const page = @import("page.zig");
const repository_page = @import("pages/repository.zig");
const review_layout = @import("pages/review/layout.zig");
const review_message = @import("pages/review/message.zig");

const MousePane = enum {
    sidebar,
    diff,
};

const ActiveDiffSelectionOwner = union(enum) {
    review: *const diff_selection.Owner,
    compare: *const diff_selection.Owner,

    fn active(self: ActiveDiffSelectionOwner) bool {
        return switch (self) {
            inline .review, .compare => |owner| owner.activeMouseSelection(),
        };
    }
};

const MousePoint = diff_surface.MousePoint;
const sidebar_header_rows: u16 = review_layout.sidebar_header_rows;

pub const ReviewContext = struct {
    key: app_input.ReviewContext,
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
    key: repository_page.InputContext,
    page_state: *const repository_page.RepositoryPageState,
};

pub const View = struct {
    active_page: page.Id,
    review: ReviewContext,
    compare: CompareContext,
    repository: RepositoryContext,
    commit_panel_mode: bool,
    repo_picker_mode: bool,
    repo_picker_input_mode: app_prompt.RepoPickerInputMode,
    keymap: keymap.Effective,
    overlay: *const app_state.OverlayState,
    layout: app_shell_layout.Layout,

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
            .review = self.review.key,
            .compare = self.compare.key,
            .repository = self.repository.key,
            .commit_panel_mode = self.commit_panel_mode,
            .repo_picker_mode = self.repo_picker_mode,
            .repo_picker_input_mode = self.repo_picker_input_mode,
            .help_mode = self.overlay.isHelp(),
            .discard_confirmation_mode = self.overlay.isDiscardFile(),
            .amend_confirmation_mode = self.overlay.isAmendCommit(),
            .push_confirmation_mode = self.overlay.isPushBranch(),
            .pull_confirmation_mode = self.overlay.isPullBranch(),
            .branch_switch_mode = self.overlay.isSwitchBranch(),
            .push_error_mode = self.overlay.isPushError(),
            .push_credential_mode = self.overlay.isPushCredentials(),
            .keymap = self.keymap,
        };
    }

    fn mouseToMsg(self: View, mouse: anytype) ?app_message.Msg {
        if (self.activeDiffSelectionOwner()) |selection| {
            if (selection.active()) switch (selection) {
                .review => switch (mouse.type) {
                    .drag => return .{ .review = .{ .mouse_diff_drag = self.bodyMousePoint(mouse) } },
                    .release => return .{ .review = .{ .mouse_diff_release = self.bodyMousePoint(mouse) } },
                    else => {},
                },
                .compare => switch (mouse.type) {
                    .drag => return .{ .compare = .{ .shared = .{ .mouse_diff_drag = self.bodyMousePoint(mouse) } } },
                    .release => return .{ .compare = .{ .shared = .{ .mouse_diff_release = self.bodyMousePoint(mouse) } } },
                    else => {},
                },
            };
        }

        if (self.repository.page_state.activeMouseOwner()) {
            const body_point: ?repository_page.BodyPoint = if (self.bodyMousePoint(mouse)) |point|
                .{ .col = point.col, .row = point.row }
            else
                null;
            const source_point = repository_page.sourceGesturePoint(
                body_point,
                self.layout.bodySize(),
                self.repository.page_state.viewer.tree_width,
                self.repository.page_state.viewer.tree_hidden,
            );
            switch (mouse.type) {
                .drag => return .{ .repository = .{ .mouse_owner_drag = source_point } },
                .release => return .{ .repository = .{ .mouse_owner_release = source_point } },
                else => {},
            }
        }

        if ((self.active_page == .review and (self.review.key.search_mode or self.review.key.file_search_mode)) or
            (self.active_page == .compare and (self.compare.key.search_mode or self.compare.key.file_search_mode or self.compare.key.base_picker_open)) or
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
            .scroll_push_error => return switch (mouse.button) {
                .wheel_up => .push_error_scroll_up,
                .wheel_down => .push_error_scroll_down,
                else => null,
            },
        }

        if (mouse.button == .left) {
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
            const pane = self.compareMousePane(mouse) orelse return null;
            return switch (mouse.button) {
                .left => switch (pane) {
                    .sidebar => .{ .compare = .{ .shared = self.compareSidebarClickToMsg(mouse) } },
                    .diff => .{ .compare = .{ .shared = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } } },
                },
                .wheel_up => .{ .compare = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up } },
                .wheel_down => .{ .compare = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down } },
                .wheel_left => if (pane == .diff) .{ .compare = .{ .shared = .mouse_diff_wheel_left } } else null,
                .wheel_right => if (pane == .diff) .{ .compare = .{ .shared = .mouse_diff_wheel_right } } else null,
                else => null,
            };
        }
        if (self.active_page != .review) return null;

        const pane = self.reviewMousePane(mouse) orelse return null;
        return switch (mouse.button) {
            .left => switch (pane) {
                .sidebar => .{ .review = self.reviewSidebarClickToMsg(mouse) },
                .diff => .{ .review = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } },
            },
            .wheel_up => .{ .review = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up },
            .wheel_down => .{ .review = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down },
            .wheel_left => if (pane == .diff) .{ .review = .mouse_diff_wheel_left } else null,
            .wheel_right => if (pane == .diff) .{ .review = .mouse_diff_wheel_right } else null,
            else => null,
        };
    }

    fn activeDiffSelectionOwner(self: View) ?ActiveDiffSelectionOwner {
        return switch (self.active_page) {
            .review => .{ .review = self.review.selection_owner },
            .compare => .{ .compare = self.compare.selection_owner },
            .repository, .config => null,
        };
    }

    fn compareMousePane(self: View, mouse: anytype) ?MousePane {
        _ = self.compare.loaded orelse return null;
        const point = self.bodyMousePoint(mouse) orelse return null;
        if (self.compare.sidebar_hidden) return .diff;
        const sidebar_width = review_layout.sidebarWidth(
            self.layout.content.width,
            self.compare.sidebar_width,
        );
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn compareSidebarClickToMsg(self: View, mouse: anytype) diff_surface.message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.layout.body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;
        const loaded = self.compare.loaded orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(
            self.compare.selected_node,
            visible_rows,
            body_row,
        ) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    fn reviewMousePane(self: View, mouse: anytype) ?MousePane {
        _ = self.review.loaded orelse return null;
        const point = self.bodyMousePoint(mouse) orelse return null;
        if (self.review.sidebar_hidden) return .diff;
        const sidebar_width = review_layout.sidebarWidth(
            self.layout.content.width,
            self.review.sidebar_width,
        );
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn reviewSidebarClickToMsg(self: View, mouse: anytype) review_message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.layout.body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;
        const loaded = self.review.loaded orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(
            self.review.selected_node,
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
};

pub const OverlayScrollController = struct {
    overlay: *app_state.OverlayState,
    content_size: chasen.Size,
    push_error_message: ?[]const u8,

    pub fn scrollHelp(self: OverlayScrollController, delta: isize) void {
        self.overlay.help_scroll = applySignedScroll(self.overlay.help_scroll, delta);
        self.clampHelp();
    }

    pub fn pageHelp(self: OverlayScrollController, pages: isize) void {
        const rows = @max(@as(usize, app_view.helpVisibleRows(self.content_size)), 1);
        self.scrollHelp(pageDelta(rows, pages));
    }

    pub fn clampHelp(self: OverlayScrollController) void {
        self.overlay.help_scroll = @min(
            self.overlay.help_scroll,
            app_view.helpMaxScroll(self.content_size),
        );
    }

    pub fn scrollPushError(self: OverlayScrollController, delta: isize) void {
        self.overlay.push_error_scroll = applySignedScroll(self.overlay.push_error_scroll, delta);
        self.clampPushError();
    }

    pub fn pagePushError(self: OverlayScrollController, pages: isize) void {
        const rows = @max(@as(usize, app_view.pushErrorVisibleRows(
            self.content_size,
            self.push_error_message,
        )), 1);
        self.scrollPushError(pageDelta(rows, pages));
    }

    pub fn clampPushError(self: OverlayScrollController) void {
        self.overlay.push_error_scroll = @min(
            self.overlay.push_error_scroll,
            app_view.pushErrorMaxScroll(self.content_size, self.push_error_message),
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
