const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_actions = @import("app/actions.zig");
const app_commit_panel = @import("app/commit_panel.zig");
const app_input = @import("app/input.zig");
const app_load_state = @import("app/load_state.zig");
const app_load = @import("app/load.zig");
const app_prompt = @import("app/prompt.zig");
const app_review_projection = @import("app/review_projection.zig");
const app_state = @import("app/state.zig");
const app_view = @import("app/view.zig");
const context = @import("context.zig");
const context_export = @import("context_export.zig");
const diff_parser = @import("diff/parser.zig");
const diff_file = @import("diff/file.zig");
const diff_hunk_projection = @import("diff/hunk_projection.zig");
const diff_patch = @import("diff/patch.zig");
const diff_render = @import("diff/render.zig");
const diff_search = @import("diff/search.zig");
const diff_source = @import("diff/source.zig");
const diff_view_model = @import("diff/view_model.zig");
const editor = @import("editor.zig");
const file_tree = @import("file_tree.zig");
const git_status = @import("git/status.zig");
const loaded_diff = @import("loaded_diff.zig");
const repo_discovery = @import("repo/discovery.zig");
const review_session = @import("review/session.zig");
const repo_state = @import("repo/state.zig");
const review_state = @import("review/state.zig");

const auto_reload_timer_id = "gitframe.auto_reload";
const auto_reload_interval_ns = 2 * std.time.ns_per_s;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(App.Msg);
const EmptyReason = app_load_state.EmptyReason;
const LoadedSession = app_load_state.LoadedSession;
const Focus = app_input.Focus;
const LoadedDiff = loaded_diff.LoadedDiff;
const LoadRuntimeState = app_load_state.LoadRuntimeState;
const PendingLoad = app_load_state.PendingLoad;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(App.Msg);
const RepoPathDiscoveryFinished = app_load.RepoPathDiscoveryFinished;
const RepoPathDiscoveryTask = app_load.RepoPathDiscoveryTask(App.Msg);
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(App.Msg);
const ReviewProjectionFinished = app_load.ReviewProjectionFinished;
const ReviewProjectionTask = app_load.ReviewProjectionTask(App.Msg);
const AmendFinished = app_actions.AmendFinished;
const AmendTask = app_actions.AmendTask(App.Msg);
const CommitFinished = app_actions.CommitFinished;
const CommitTask = app_actions.CommitTask(App.Msg);
const DiscardFileFinished = app_actions.DiscardFileFinished;
const DiscardFileTask = app_actions.DiscardFileTask(App.Msg);
const StageHunkFinished = app_actions.StageHunkFinished;
const StageHunkTask = app_actions.StageHunkTask(App.Msg);
const StageFileFinished = app_actions.StageFileFinished;
const StageFileTask = app_actions.StageFileTask(App.Msg);
const UnstageFileFinished = app_actions.UnstageFileFinished;
const UnstageFileTask = app_actions.UnstageFileTask(App.Msg);
const UnstageHunkFinished = app_actions.UnstageHunkFinished;
const UnstageHunkTask = app_actions.UnstageHunkTask(App.Msg);

const MousePane = enum {
    sidebar,
    diff,
};

const MousePoint = struct {
    col: u16,
    row: u16,
};

pub const ActiveDiffDisplay = union(enum) {
    loaded: struct {
        file: diff_parser.FileDiff,
        line_index: ?diff_view_model.RenderedLineIndex,
        folded_hunks: []const bool,
        staged_flags: []const bool,
    },
    combined_projection: struct {
        file: diff_parser.FileDiff,
        line_index: diff_view_model.RenderedLineIndex,
        staged_flags: []const bool,
        hunk_states: []const diff_hunk_projection.ProjectedHunkState,
    },

    pub fn file(self: ActiveDiffDisplay) diff_parser.FileDiff {
        return switch (self) {
            .loaded => |loaded| loaded.file,
            .combined_projection => |projection| projection.file,
        };
    }

    pub fn lineIndex(self: ActiveDiffDisplay) ?diff_view_model.RenderedLineIndex {
        return switch (self) {
            .loaded => |loaded| loaded.line_index,
            .combined_projection => |projection| projection.line_index,
        };
    }

    pub fn foldedHunks(self: ActiveDiffDisplay) []const bool {
        return switch (self) {
            .loaded => |loaded| loaded.folded_hunks,
            .combined_projection => &.{},
        };
    }

    pub fn stagedFlags(self: ActiveDiffDisplay) []const bool {
        return switch (self) {
            .loaded => |loaded| loaded.staged_flags,
            .combined_projection => |projection| projection.staged_flags,
        };
    }
};

const RepoPickerItemSource = union(enum) {
    active_repo,
    workspace_repo: usize,
    pending_workspace_repo: usize,
    recent_repo: usize,
    recent_workspace: usize,
};

const RepoPickerItem = struct {
    label: []u8,
    detail: []u8,
    source: RepoPickerItemSource,

    fn deinit(self: *RepoPickerItem, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

const ViewerState = struct {
    /// Sticky target shown in the diff pane or used by file actions.
    ///
    /// Directory sidebar rows can be selected without changing this value.
    selected_target: ?context.SelectedTarget = .{ .diff_file = 0 },
    /// Transitional cache for older tests and helpers. Runtime reads should go
    /// through selectedFileIndex().
    /// TODO(phase8): remove after status-only targets replace diff-file-only
    /// assumptions across the app.
    selected_file: usize = 0,
    /// Sidebar cursor. This may point at a directory, diff file, or later a
    /// status-only row; it is not necessarily the action target.
    selected_node: usize = 0,
    focus: Focus = .sidebar,
    sidebar_hidden: bool = false,
    sidebar_width: ?u16 = null,
    diff_scroll: usize = 0,
    diff_horizontal_scroll: usize = 0,
    diff_cursor: diff_view_model.BodyCoordinate = .{ .metadata = 0 },
    display_mode: diff_render.DisplayMode = .side_by_side,
    view_options: ViewOptions = .{},
};

const ViewOptions = struct {
    line_numbers: bool = true,

    fn toggleLineNumbers(self: *ViewOptions) void {
        self.line_numbers = !self.line_numbers;
    }
};

fn expandUserPath(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    const home_path = home orelse return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home_path);
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(allocator, &.{ home_path, path[2..] });
    }
    return allocator.dupe(u8, path);
}

const DiffSearchState = struct {
    mode: bool = false,
    input: app_prompt.TextInput = .{},
    query: app_prompt.TextInput = .{},
    match: ?diff_search.Match = null,
    /// Rendered body-line offset cache for match. Recomputed when display
    /// mode, fold state, or selected file changes.
    match_offset: ?usize = null,
};

const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const OverlayKind = app_state.OverlayKind;

pub const App = struct {
    config: CliConfig = .{},
    env_map: ?*std.process.Environ.Map = null,
    review_output: ?*review_session.Output = null,
    allocator: ?std.mem.Allocator = null,
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    actions: app_actions.ActionState = .{},
    load: LoadRuntimeState = .{},
    status: app_state.StatusMessage = .{},
    viewer: ViewerState = .{},
    search: DiffSearchState = .{},
    commit_panel: app_commit_panel.State = .{},
    file_search: app_prompt.FilterPromptState = .{},
    file_search_return_focus: Focus = .sidebar,
    repo_picker: app_prompt.RepoPickerState = .{},
    /// Workspace discovered from path input but not yet selected.
    ///
    /// Keeping this outside repo_state lets the picker show candidates without
    /// changing the active repository until the user presses Enter on a repo.
    repo_picker_discovery: ?repo_discovery.DiscoveryResult = null,
    repo_picker_items: std.ArrayList(RepoPickerItem) = .empty,
    recent_repos: repo_state.RecentStore = .{},
    overlay: app_state.OverlayState = .{},
    review_display: app_state.ReviewDisplayState = .{},
    staged_hunks: app_state.StagedHunkMarks = .{},
    review_projection: app_review_projection.State = .idle,
    review_projection_next_id: u64 = 0,
    repo_state: repo_state.State = .{},
    git_status: git_status.GitStatusState = .{},
    status_load_generation: u64 = 0,
    status_load_pending: ?u64 = null,
    /// One-shot startup selection intent used when diff finishes before status.
    pending_initial_first_visible_selection: bool = false,
    tree_order: file_tree.StableOrder = .{},
    tree_order_scope: ?[]u8 = null,
    pending_selection_restore: ?app_state.PendingSelectionRestore = null,
    /// Session-level source of truth for reviewed files. The active LoadedDiff
    /// keeps a materialized bool slice so hide-reviewed hot paths stay O(1).
    reviewed_store: review_state.Store = .{},
    discard_confirmation: ?app_state.DiscardFileConfirmation = null,
    amend_confirmation: ?app_state.AmendConfirmation = null,

    pub const Msg = union(enum) {
        terminal_resized: chasen.Size,
        repos_discovered: RepoDiscoveryFinished,
        repo_path_discovered: app_load.RepoPathDiscoveryFinished,
        diff_loaded: DiffLoadFinished,
        status_loaded: StatusLoadFinished,
        review_projection_loaded: ReviewProjectionFinished,
        stage_file_finished: StageFileFinished,
        stage_hunk_finished: StageHunkFinished,
        unstage_file_finished: UnstageFileFinished,
        unstage_hunk_finished: UnstageHunkFinished,
        discard_file_finished: DiscardFileFinished,
        commit_finished: CommitFinished,
        amend_finished: AmendFinished,
        select_previous_file,
        select_next_file,
        toggle_directory,
        expand_directory,
        collapse_or_parent_directory,
        scroll_diff_up,
        scroll_diff_down,
        scroll_diff_left,
        scroll_diff_right,
        page_diff_up,
        page_diff_down,
        select_previous_hunk,
        select_next_hunk,
        toggle_hunk_fold,
        select_first_file,
        select_last_file,
        toggle_focus,
        toggle_sidebar_visibility,
        decrease_sidebar_width,
        increase_sidebar_width,
        focus_sidebar,
        focus_diff,
        sidebar_click_node: usize,
        mouse_sidebar_wheel_up,
        mouse_sidebar_wheel_down,
        mouse_diff_wheel_up,
        mouse_diff_wheel_down,
        mouse_diff_wheel_left,
        mouse_diff_wheel_right,
        toggle_display_mode,
        toggle_line_numbers,
        enter_search,
        cancel_search,
        clear_search,
        submit_search,
        search_insert: u21,
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
        search_paste: []const u8,
        search_backspace,
        search_move_left,
        search_move_right,
        select_next_search_match,
        select_previous_search_match,
        enter_file_search,
        cancel_file_search,
        submit_file_search,
        file_search_insert: u21,
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
        file_search_paste: []const u8,
        file_search_backspace,
        enter_commit_panel,
        enter_amend_panel,
        cancel_commit_panel,
        submit_commit_panel,
        commit_panel_tab,
        commit_panel_enter,
        commit_panel_insert: u21,
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
        commit_panel_paste: []const u8,
        commit_panel_backspace,
        commit_panel_move_left,
        commit_panel_move_right,
        commit_panel_move_up,
        commit_panel_move_down,
        enter_repo_picker,
        cancel_repo_picker,
        submit_repo_picker,
        repo_picker_enter_path_input,
        repo_picker_insert: u21,
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
        repo_picker_paste: []const u8,
        repo_picker_backspace,
        repo_picker_move_previous,
        repo_picker_move_next,
        repo_picker_move_left,
        repo_picker_move_right,
        open_help,
        close_help,
        help_scroll_up,
        help_scroll_down,
        help_page_up,
        help_page_down,
        toggle_reviewed_file,
        toggle_hide_reviewed_files,
        cycle_changed_file_filter,
        stage_selected_file,
        stage_selected_hunk,
        unstage_selected_file,
        unstage_selected_hunk,
        request_discard_selected_file,
        confirm_discard_file,
        cancel_discard_file,
        confirm_amend,
        cancel_amend,
        open_selected_file_in_editor,
        editor_finished: chasen.ForegroundCommandResult,
        finish_review_approved,
        finish_review_needs_changes,
        finish_review_canceled,
        reload,
        auto_reload_tick,
        quit,
    };

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.commit_panel = app_commit_panel.State.init(ctx.allocator());
        if (self.config.watch) {
            try ctx.timer().every(auto_reload_timer_id, auto_reload_interval_ns, .auto_reload_tick);
        }
        if (diff_source.sourceRequiresRepo(self.config.source)) {
            try self.startRepoDiscovery(ctx);
        } else {
            try self.startDiffLoad(ctx);
        }
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        if (self.allocator == null) self.allocator = deinit_ctx.allocator;
        self.clearLoadedDiff();
        self.repo_state.deinit(deinit_ctx.allocator);
        self.git_status.deinit();
        self.file_search.deinit(deinit_ctx.allocator);
        self.commit_panel.deinit();
        self.repo_picker.deinit(deinit_ctx.allocator);
        self.clearRepoPickerDiscovery(deinit_ctx.allocator);
        self.deinitRepoPickerItems(deinit_ctx.allocator);
        self.recent_repos.deinit(deinit_ctx.allocator);
        self.reviewed_store.deinit(deinit_ctx.allocator);
        self.staged_hunks.deinit(deinit_ctx.allocator);
        self.review_projection.deinit(deinit_ctx.allocator);
        self.cancelDiscardConfirmation(deinit_ctx.allocator);
        self.cancelAmendConfirmation(deinit_ctx.allocator);
        self.tree_order.deinit(deinit_ctx.allocator);
        if (self.tree_order_scope) |scope| deinit_ctx.allocator.free(scope);
        if (self.pending_selection_restore) |*restore| restore.deinit(deinit_ctx.allocator);
    }

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .terminal_resized => |size| {
                const previous_width = self.diffPaneWidth();
                self.terminal_size = size;
                self.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                self.clampDiffNavigationKeepingHunkVisible();
                self.updateSearchMatchOffset();
                self.scrollSearchMatchIntoView();
                self.clampDiffNavigation();
                self.clampHelpScroll();
            },
            .repos_discovered => |finished| try self.finishRepoDiscovery(ctx, finished),
            .repo_path_discovered => |finished| try self.finishRepoPathDiscovery(ctx, finished),
            .diff_loaded => |finished| try self.finishDiffLoad(ctx, finished),
            .status_loaded => |finished| try self.finishStatusLoad(ctx, finished),
            .review_projection_loaded => |finished| try self.finishReviewProjectionLoad(ctx, finished),
            .stage_file_finished => |finished| try self.finishStageFile(ctx, finished),
            .stage_hunk_finished => |finished| try self.finishStageHunk(ctx, finished),
            .unstage_file_finished => |finished| try self.finishUnstageFile(ctx, finished),
            .unstage_hunk_finished => |finished| try self.finishUnstageHunk(ctx, finished),
            .discard_file_finished => |finished| try self.finishDiscardFile(ctx, finished),
            .commit_finished => |finished| try self.finishCommit(ctx, finished),
            .amend_finished => |finished| try self.finishAmend(ctx, finished),
            .select_previous_file => self.selectFileDelta(-1),
            .select_next_file => self.selectFileDelta(1),
            .toggle_directory => try self.toggleSelectedDirectory(),
            .expand_directory => try self.expandSelectedDirectory(),
            .collapse_or_parent_directory => try self.collapseOrSelectParentDirectory(),
            .scroll_diff_up => self.moveDiffCursorRows(-1),
            .scroll_diff_down => self.moveDiffCursorRows(1),
            .scroll_diff_left => self.scrollDiffHorizontal(-1),
            .scroll_diff_right => self.scrollDiffHorizontal(1),
            .page_diff_up => self.moveDiffCursorPage(-1),
            .page_diff_down => self.moveDiffCursorPage(1),
            .select_previous_hunk => self.selectHunkDelta(-1),
            .select_next_hunk => self.selectHunkDelta(1),
            .toggle_hunk_fold => self.toggleSelectedHunkFold(),
            .select_first_file => self.selectFileAbsolute(0),
            .select_last_file => self.selectLastFile(),
            .toggle_focus => {
                if (!self.viewer.sidebar_hidden) self.viewer.focus = self.viewer.focus.toggled();
            },
            .toggle_sidebar_visibility => self.toggleSidebarVisibility(),
            .decrease_sidebar_width => self.adjustSidebarWidth(-1),
            .increase_sidebar_width => self.adjustSidebarWidth(1),
            .focus_sidebar => {
                if (!self.viewer.sidebar_hidden) self.viewer.focus = .sidebar;
            },
            .focus_diff => self.viewer.focus = .diff,
            .sidebar_click_node => |node_index| try self.clickSidebarNode(node_index),
            .mouse_sidebar_wheel_up => {
                if (!self.viewer.sidebar_hidden) self.viewer.focus = .sidebar;
                self.selectFileDelta(-1);
            },
            .mouse_sidebar_wheel_down => {
                if (!self.viewer.sidebar_hidden) self.viewer.focus = .sidebar;
                self.selectFileDelta(1);
            },
            .mouse_diff_wheel_up => {
                self.viewer.focus = .diff;
                self.scrollDiff(-1);
            },
            .mouse_diff_wheel_down => {
                self.viewer.focus = .diff;
                self.scrollDiff(1);
            },
            .mouse_diff_wheel_left => {
                self.viewer.focus = .diff;
                self.scrollDiffHorizontal(-1);
            },
            .mouse_diff_wheel_right => {
                self.viewer.focus = .diff;
                self.scrollDiffHorizontal(1);
            },
            .toggle_display_mode => {
                const old_mode = self.effectiveDisplayMode();
                const old_scroll = self.viewer.diff_scroll;
                self.viewer.display_mode = self.viewer.display_mode.toggled();
                const new_mode = self.effectiveDisplayMode();
                self.viewer.diff_scroll = self.remapDiffScrollForModeChange(old_mode, new_mode, old_scroll);
                self.resetDiffHorizontalScroll();
                self.updateSearchMatchOffset();
                self.scrollSearchMatchIntoView();
                self.applyDiffCursorScrolloff();
                self.clampDiffNavigation();
            },
            .toggle_line_numbers => {
                self.viewer.view_options.toggleLineNumbers();
                self.clampDiffHorizontalScrollToVisibleRows();
            },
            .enter_search => self.enterSearchMode(),
            .cancel_search => self.cancelSearchMode(),
            .clear_search => self.clearSearch(),
            .submit_search => self.submitSearch(),
            .search_insert => |codepoint| self.search.input.insert(codepoint) catch {},
            .search_paste => |text| self.search.input.insertSlice(text) catch {
                self.setStatus("search paste is too long", .{});
            },
            .search_backspace => self.search.input.backspace(),
            .search_move_left => self.search.input.moveLeft(),
            .search_move_right => self.search.input.moveRight(),
            .select_next_search_match => self.selectSearchMatch(.forward),
            .select_previous_search_match => self.selectSearchMatch(.backward),
            .enter_file_search => self.enterFileSearchMode(),
            .cancel_file_search => self.cancelFileSearchMode(ctx.allocator()),
            .submit_file_search => try self.submitFileSearch(ctx.allocator()),
            .file_search_insert => |codepoint| {
                self.file_search.resetNoMatch();
                self.file_search.input.insert(codepoint) catch {};
            },
            .file_search_paste => |text| {
                self.file_search.resetNoMatch();
                self.file_search.input.insertSlice(text) catch {
                    self.setStatus("file search paste is too long", .{});
                };
            },
            .file_search_backspace => {
                self.file_search.resetNoMatch();
                self.file_search.input.backspace();
            },
            .enter_commit_panel => self.enterCommitPanelMode(.commit),
            .enter_amend_panel => self.enterCommitPanelMode(.amend),
            .cancel_commit_panel => self.commit_panel.close(),
            .submit_commit_panel => try self.submitCommitPanel(ctx),
            .commit_panel_tab => self.commit_panel.toggleField(),
            .commit_panel_enter => self.commit_panel.enter(),
            .commit_panel_insert => |codepoint| self.commit_panel.insert(codepoint),
            .commit_panel_paste => |text| self.commit_panel.paste(text),
            .commit_panel_backspace => self.commit_panel.backspace(),
            .commit_panel_move_left => self.commit_panel.moveLeft(),
            .commit_panel_move_right => self.commit_panel.moveRight(),
            .commit_panel_move_up => self.commit_panel.moveUp(),
            .commit_panel_move_down => self.commit_panel.moveDown(),
            .enter_repo_picker => try self.enterRepoPickerMode(ctx.allocator()),
            .cancel_repo_picker => self.cancelRepoPickerMode(ctx.allocator()),
            .submit_repo_picker => try self.submitRepoPicker(ctx),
            .repo_picker_enter_path_input => self.enterRepoPickerPathInput(),
            .repo_picker_insert => |codepoint| {
                try self.insertRepoPickerCodepoint(ctx.allocator(), codepoint);
            },
            .repo_picker_paste => |text| {
                try self.insertRepoPickerSlice(ctx.allocator(), text);
            },
            .repo_picker_backspace => {
                try self.backspaceRepoPicker(ctx.allocator());
            },
            .repo_picker_move_previous => self.repo_picker.list.filter.update(.move_prev),
            .repo_picker_move_next => self.repo_picker.list.filter.update(.move_next),
            .repo_picker_move_left => self.moveRepoPickerCursorLeft(),
            .repo_picker_move_right => self.moveRepoPickerCursorRight(),
            .open_help => {
                self.overlay.openHelp();
            },
            .close_help => self.overlay.close(),
            .help_scroll_up => self.scrollHelp(-1),
            .help_scroll_down => self.scrollHelp(1),
            .help_page_up => self.pageHelp(-1),
            .help_page_down => self.pageHelp(1),
            .toggle_reviewed_file => try self.toggleReviewedFile(ctx.allocator()),
            .toggle_hide_reviewed_files => try self.toggleHideReviewedFiles(),
            .cycle_changed_file_filter => try self.cycleChangedFileFilter(),
            .stage_selected_file => try self.stageSelectedFile(ctx),
            .stage_selected_hunk => try self.stageSelectedHunk(ctx),
            .unstage_selected_file => try self.unstageSelectedFile(ctx),
            .unstage_selected_hunk => try self.unstageSelectedHunk(ctx),
            .request_discard_selected_file => try self.requestDiscardSelectedFile(ctx.allocator()),
            .confirm_discard_file => try self.confirmDiscardFile(ctx),
            .cancel_discard_file => self.cancelDiscardConfirmation(ctx.allocator()),
            .confirm_amend => try self.confirmAmend(ctx),
            .cancel_amend => self.cancelAmendConfirmation(ctx.allocator()),
            .open_selected_file_in_editor => try self.openSelectedFileInEditor(ctx),
            .editor_finished => |result| try self.finishEditorCommand(ctx, result),
            .finish_review_approved => try self.finishReview(ctx, .approved),
            .finish_review_needs_changes => try self.finishReview(ctx, .needs_changes),
            .finish_review_canceled => try self.finishReview(ctx, .canceled),
            .reload => {
                self.clearPendingSelectionRestore(ctx.allocator());
                if (diff_source.sourceIsOneShotInput(self.config.source)) {
                    ctx.redraw().skip();
                } else if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
                    try self.startRepoDiscovery(ctx);
                } else {
                    try self.startDiffLoad(ctx);
                }
            },
            .auto_reload_tick => try self.autoReloadTick(ctx),
            .quit => ctx.quit(),
        }
        try self.ensureReviewProjection(ctx);
    }

    pub fn view(self: *const App, surface: *chasen.Surface) !void {
        return app_view.view(self, surface);
    }

    pub fn handleEvent(self: *const App, event: chasen.Event) ?Msg {
        return switch (event) {
            .mouse => |mouse| self.mouseToMsg(mouse),
            else => app_input.eventToMsg(Msg, self.keyContext(), event),
        };
    }

    fn mouseToMsg(self: *const App, mouse: anytype) ?Msg {
        if (self.search.mode or self.file_search.mode or self.commit_panel.is_open or self.repo_picker.mode) return null;
        if (mouse.type != .press) return null;

        if (self.overlay.isHelp()) {
            return switch (mouse.button) {
                .wheel_up => .help_scroll_up,
                .wheel_down => .help_scroll_down,
                else => null,
            };
        }

        const pane = self.mousePane(mouse) orelse return null;
        return switch (mouse.button) {
            .left => switch (pane) {
                .sidebar => self.sidebarClickToMsg(mouse),
                .diff => .focus_diff,
            },
            .wheel_up => switch (pane) {
                .sidebar => .mouse_sidebar_wheel_up,
                .diff => .mouse_diff_wheel_up,
            },
            .wheel_down => switch (pane) {
                .sidebar => .mouse_sidebar_wheel_down,
                .diff => .mouse_diff_wheel_down,
            },
            .wheel_left => switch (pane) {
                .sidebar => null,
                .diff => .mouse_diff_wheel_left,
            },
            .wheel_right => switch (pane) {
                .sidebar => null,
                .diff => .mouse_diff_wheel_right,
            },
            else => null,
        };
    }

    fn mousePane(self: *const App, mouse: anytype) ?MousePane {
        _ = self.activeLoadedDiffConst() orelse return null;

        const point = self.bodyMousePoint(mouse) orelse return null;
        const size = self.layoutSize();
        if (self.viewer.sidebar_hidden) return .diff;

        const sidebar_width = sidebarWidth(size.width, self.viewer.sidebar_width);
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn sidebarClickToMsg(self: *const App, mouse: anytype) Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = terminalBodyHeight(self.layoutSize().height);
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;

        const loaded = self.activeLoadedDiffConst() orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(self.viewer.selected_node, visible_rows, body_row) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    fn bodyMousePoint(self: *const App, mouse: anytype) ?MousePoint {
        const point = self.contentMousePoint(mouse) orelse return null;
        if (point.row >= terminalBodyHeight(self.layoutSize().height)) return null;
        return point;
    }

    fn contentMousePoint(self: *const App, mouse: anytype) ?MousePoint {
        if (mouse.col < 0 or mouse.row < 0) return null;

        const raw_col: usize = @intCast(mouse.col);
        const raw_row: usize = @intCast(mouse.row);
        const rect = app_view.shellContentRect(self.terminal_size);
        const rect_col: usize = rect.col;
        const rect_row: usize = rect.row;
        const rect_width: usize = rect.width;
        const rect_height: usize = rect.height;

        if (raw_col < rect_col or raw_row < rect_row) return null;
        if (raw_col >= rect_col + rect_width or raw_row >= rect_row + rect_height) return null;

        return .{
            .col = @intCast(raw_col - rect_col),
            .row = @intCast(raw_row - rect_row),
        };
    }

    fn keyContext(self: *const App) app_input.KeyContext {
        return .{
            .search_mode = self.search.mode,
            .file_search_mode = self.file_search.mode,
            .commit_panel_mode = self.commit_panel.is_open,
            .repo_picker_mode = self.repo_picker.mode,
            .help_mode = self.overlay.isHelp(),
            .discard_confirmation_mode = self.overlay.isDiscardFile(),
            .amend_confirmation_mode = self.overlay.isAmendCommit(),
            .search_query_len = self.search.query.len,
            .focus = self.viewer.focus,
            .sidebar_hidden = self.viewer.sidebar_hidden,
            .repo_picker_path_input = self.repo_picker.prompt_mode == .path_input,
            .review_mode = self.config.review_mode,
        };
    }

    fn scrollHelp(self: *App, delta: isize) void {
        if (delta < 0) {
            const amount: usize = @intCast(-(delta + 1));
            self.overlay.help_scroll -|= amount + 1;
        } else {
            self.overlay.help_scroll +|= @intCast(delta);
        }
        self.clampHelpScroll();
    }

    fn pageHelp(self: *App, pages: isize) void {
        const rows = @max(@as(usize, app_view.helpVisibleRows(self.layoutSize())), 1);
        const delta: isize = if (pages < 0)
            -@as(isize, @intCast(rows))
        else
            @as(isize, @intCast(rows));
        self.scrollHelp(delta);
    }

    fn clampHelpScroll(self: *App) void {
        self.overlay.help_scroll = @min(self.overlay.help_scroll, app_view.helpMaxScroll(self.layoutSize()));
    }

    fn viewSidebar(self: *const App, surface: *chasen.Surface, loaded: LoadedDiff) !void {
        return app_view.viewSidebar(self, surface, loaded);
    }

    fn viewDiffPane(self: *const App, surface: *chasen.Surface, loaded: LoadedDiff) !void {
        return app_view.viewDiffPane(self, surface, loaded);
    }

    fn drawSearchMatchMarker(self: *const App, surface: *chasen.Surface) void {
        app_view.drawSearchMatchMarker(self, surface);
    }

    fn startRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const task = try ctx.allocator().create(RepoDiscoveryTask);
        errdefer ctx.allocator().destroy(task);

        const generation = self.load.beginRepoDiscovery();
        task.* = .{ .generation = generation };
        self.clearLoadedDiff();
        self.load.state = .loading;
        ctx.task().spawnWith(task, RepoDiscoveryTask.run) catch |err| {
            _ = self.load.clearPendingIfCurrent(.{ .repo_discovery = generation });
            try self.storeFailedMessage(ctx.allocator(), "Could not start repo discovery task");
            return err;
        };
    }

    fn finishRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg), finished: RepoDiscoveryFinished) !void {
        var result = finished.result;
        defer result.deinit(ctx.allocator());

        _ = self.load.finishPending(.{ .repo_discovery = finished.generation });
        if (!self.load.isCurrent(finished.generation)) return;

        switch (result) {
            .empty => unreachable,
            .discovered => |discovery| {
                try self.rememberDiscovery(ctx.allocator(), discovery);
                result = .empty;
                self.repo_state.replace(ctx.allocator(), discovery);

                if (self.activeRepoRoot() == null) {
                    self.clearLoadedDiff();
                    self.load.replaceEmpty(ctx.allocator(), .no_repository);
                    return;
                }

                try self.startDiffLoad(ctx);
            },
            .failed => |message| {
                try self.storeFailedMessage(ctx.allocator(), std.mem.trim(u8, message, " \t\r\n"));
            },
            .failed_static => |message| {
                try self.storeFailedMessage(ctx.allocator(), message);
            },
        }
    }

    fn rememberDiscovery(self: *App, allocator: std.mem.Allocator, discovery: repo_discovery.DiscoveryResult) !void {
        switch (discovery) {
            .single_repo => |entry| try self.recent_repos.rememberRepo(allocator, entry.canonical_root),
            .workspace => |workspace| {
                try self.recent_repos.rememberWorkspace(allocator, workspace.current_root);
                if (workspace.repos.len > 0) try self.recent_repos.rememberRepo(allocator, workspace.repos[0].canonical_root);
            },
            .none => {},
        }
    }

    fn startDiffLoad(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const repo_root = self.repoRootForCurrentSource() catch |err| {
            self.load.replaceEmpty(ctx.allocator(), switch (err) {
                error.MissingRepoRoot => .no_repository,
            });
            return;
        };

        try self.startDiffLoadWithRepoRoot(ctx, repo_root, true);
    }

    fn startDiffLoadWithRepoRoot(self: *App, ctx: *chasen.Ctx(Msg), repo_root: ?[]const u8, clear_visible_state: bool) !void {
        if (repo_root) |root| {
            self.startStatusLoad(ctx, root);
        } else {
            self.invalidateStatusSnapshot();
        }

        const task = try ctx.allocator().create(DiffLoadTask);
        errdefer ctx.allocator().destroy(task);

        const request = try diff_source.cloneLoadRequest(ctx.allocator(), .{
            .source = self.config.source,
            .repo_root = repo_root,
        });
        errdefer diff_source.freeLoadRequest(ctx.allocator(), request);

        const generation = self.load.beginDiffLoad();
        task.* = .{
            // Source payloads come from process args, so clone the request
            // before the async task crosses the update boundary.
            .request = request,
            .generation = generation,
        };

        if (clear_visible_state) {
            self.clearLoadedDiff();
            self.load.state = .loading;
        }
        ctx.task().spawnWith(task, DiffLoadTask.run) catch |err| {
            _ = self.load.clearPendingIfCurrent(.{ .diff_load = generation });
            try self.storeFailedMessage(ctx.allocator(), "Could not start diff load task");
            return err;
        };
    }

    fn startStatusLoad(self: *App, ctx: *chasen.Ctx(Msg), repo_root: []const u8) void {
        self.invalidateStatusSnapshot();

        const task = ctx.allocator().create(StatusLoadTask) catch {
            self.clearPendingSelectionRestore(ctx.allocator());
            self.setStatus("could not allocate status load task", .{});
            return;
        };

        const owned_root = ctx.allocator().dupe(u8, repo_root) catch {
            ctx.allocator().destroy(task);
            self.clearPendingSelectionRestore(ctx.allocator());
            self.setStatus("could not allocate status repo root", .{});
            return;
        };

        task.* = .{
            .repo_root = owned_root,
            .generation = self.status_load_generation,
        };
        self.status_load_pending = self.status_load_generation;

        ctx.task().spawnWith(task, StatusLoadTask.run) catch {
            // Status is auxiliary data. Keep the diff load going even if this
            // task cannot start; the invalidated generation prevents any older
            // in-flight status result from restoring a stale snapshot.
            ctx.allocator().free(owned_root);
            ctx.allocator().destroy(task);
            self.clearPendingSelectionRestore(ctx.allocator());
            self.status_load_pending = null;
            self.setStatus("could not start status load task", .{});
            return;
        };
    }

    fn invalidateStatusSnapshot(self: *App) void {
        self.status_load_generation +%= 1;
        self.status_load_pending = null;
        self.pending_initial_first_visible_selection = false;
        self.git_status.clear();
    }

    fn ensureReviewProjection(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const target = self.reviewProjectionTarget() orelse {
            if (self.review_projection != .idle) {
                self.review_projection.deinit(self.allocator orelse ctx.allocator());
            }
            return;
        };

        if (self.review_projection.matches(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.load.generation,
            self.status_load_generation,
        )) return;

        self.review_projection.deinit(ctx.allocator());
        self.review_projection_next_id +%= 1;
        var state_request = try app_review_projection.cloneRequest(
            ctx.allocator(),
            self.review_projection_next_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.load.generation,
            self.status_load_generation,
        );
        errdefer state_request.deinit(ctx.allocator());

        var task_request = try app_review_projection.cloneRequest(
            ctx.allocator(),
            self.review_projection_next_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.load.generation,
            self.status_load_generation,
        );
        var task_request_moved = false;
        errdefer if (!task_request_moved) task_request.deinit(ctx.allocator());

        const task = try ctx.allocator().create(ReviewProjectionTask);
        errdefer ctx.allocator().destroy(task);
        task.* = .{ .request = task_request };
        task_request_moved = true;

        ctx.task().spawnWith(task, ReviewProjectionTask.run) catch |err| {
            task.request.deinit(ctx.allocator());
            ctx.allocator().destroy(task);
            return err;
        };

        self.review_projection = .{ .pending = state_request };
    }

    const ProjectionTarget = struct {
        repo_root: []const u8,
        path_key: []const u8,
        kind: app_review_projection.Kind,
        source_kind: app_review_projection.SourceKind,
    };

    fn reviewProjectionTarget(self: *const App) ?ProjectionTarget {
        const repo_root = self.activeRepoRoot() orelse return null;
        const source_kind = reviewProjectionSourceKind(self.config.source);

        if (self.selectedFile()) |file| {
            const path_key = diff_file.canonicalPathKey(file) orelse return null;
            const entry = self.freshStatusEntryForPathKey(repo_root, path_key) orelse return null;
            if (sourceIsUnstaged(self.config.source) and isCombinedHunkProjectionCandidate(file, entry)) {
                return .{
                    .repo_root = repo_root,
                    .path_key = path_key,
                    .kind = .combined_hunks,
                    .source_kind = source_kind,
                };
            }
        }

        const entry = self.selectedStatusEntry() orelse return null;
        const path_key = entry.canonicalPathKey() orelse return null;

        return switch (file_tree.stagePresenceFromEntry(entry)) {
            .staged_only => .{ .repo_root = repo_root, .path_key = path_key, .kind = .cached_diff, .source_kind = source_kind },
            // Mixed files normally have an unstaged diff in the parsed document.
            // This projection is only for the status-only edge case where the
            // current source has no diff body but status still reports the path.
            .mixed => .{ .repo_root = repo_root, .path_key = path_key, .kind = .cached_diff, .source_kind = source_kind },
            .untracked => .{ .repo_root = repo_root, .path_key = path_key, .kind = .generated_added_file, .source_kind = source_kind },
            else => null,
        };
    }

    fn reviewProjectionSourceKind(source: diff_source.SourceMode) app_review_projection.SourceKind {
        return switch (source) {
            .unstaged => .unstaged,
            .cached => .cached,
            .stdin, .pager, .patch_file, .range, .no_index => .other,
        };
    }

    fn sourceIsUnstaged(source: diff_source.SourceMode) bool {
        return switch (source) {
            .unstaged => true,
            .cached, .stdin, .pager, .patch_file, .range, .no_index => false,
        };
    }

    fn isCombinedHunkProjectionCandidate(file: diff_parser.FileDiff, entry: git_status.StatusEntry) bool {
        if (file.is_binary) return false;
        if (file.hunks.len == 0) return false;
        if (entry.index != .modified or entry.worktree != .modified) return false;
        if (entry.isConflict()) return false;
        if (diff_file.status(file) != .modified) return false;
        if (diff_file.hasModeChange(file)) return false;
        return file_tree.stagePresenceFromEntry(entry) == .mixed;
    }

    fn stageSelectedFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.selectedStageTarget()) {
            .ready => |target| target,
            .already_staged => |path| {
                self.setStatus("already staged: {s}", .{path});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .conflict_unsupported => |path| {
                self.setStatus("conflict under directory: {s}", .{path});
                return;
            },
            .no_stageable_content => |path| {
                self.setStatus("no stageable files under: {s}", .{path});
                return;
            },
            .unavailable_source, .no_repo => {
                self.setStatus("stage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no stageable file selected", .{});
                return;
            },
        };
        try self.setPendingSelectionRestore(ctx.allocator(), target.path);
        errdefer self.clearPendingSelectionRestore(ctx.allocator());

        // Keep rollback active until the task is successfully handed to Chasen.
        const pending = self.actions.begin(.stage_file);
        errdefer _ = self.actions.finish(pending);

        const task = try ctx.allocator().create(StageFileTask);
        task.* = .{
            .pending = pending,
            .repo_root = &.{},
            .path = &.{},
        };
        errdefer {
            if (task.repo_root.len > 0) ctx.allocator().free(task.repo_root);
            if (task.path.len > 0) ctx.allocator().free(task.path);
            ctx.allocator().destroy(task);
        }

        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        task.path = try ctx.allocator().dupe(u8, target.path);

        ctx.task().spawnWith(task, StageFileTask.run) catch |err| {
            self.setStatus("could not start stage task", .{});
            return err;
        };
        self.setStatus("staging: {s}", .{target.path});
    }

    fn stageSelectedHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.selectedHunkStageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("hunk stage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setStatus("hunk stage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setStatus("no hunk selected", .{});
                return;
            },
            .offscreen_cursor => {
                self.setStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .conflict_unsupported => {
                self.setStatus("conflict hunk stage is not supported yet", .{});
                return;
            },
            .binary_unsupported => {
                self.setStatus("binary hunk stage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setStatus("hunk stage supports modified files only", .{});
                return;
            },
            .already_staged_hunk => {
                self.setStatus("hunk already staged", .{});
                return;
            },
            .patch_failed => {
                self.setStatus("could not build hunk patch", .{});
                return;
            },
        };

        var owned_patch = target.patch;
        errdefer if (owned_patch.len > 0) ctx.allocator().free(owned_patch);

        const pending = self.actions.begin(.stage_hunk);
        errdefer _ = self.actions.finish(pending);

        const task = try ctx.allocator().create(StageHunkTask);
        task.* = .{
            .pending = pending,
            .repo_root = &.{},
            .path = &.{},
            .patch = &.{},
            .hunk_index = target.hunk_index,
            .mark_source = target.mark_source,
        };
        errdefer {
            if (task.repo_root.len > 0) ctx.allocator().free(task.repo_root);
            if (task.path.len > 0) ctx.allocator().free(task.path);
            if (task.patch.len > 0) ctx.allocator().free(task.patch);
            ctx.allocator().destroy(task);
        }

        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        task.path = try ctx.allocator().dupe(u8, target.path);
        task.patch = owned_patch;
        owned_patch = &.{};

        ctx.task().spawnWith(task, StageHunkTask.run) catch |err| {
            self.setStatus("could not start hunk stage task", .{});
            return err;
        };
        self.setStatus("staging hunk: {s}", .{target.path});
    }

    fn unstageSelectedHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.selectedHunkUnstageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("hunk unstage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setStatus("hunk unstage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setStatus("no hunk selected", .{});
                return;
            },
            .offscreen_cursor => {
                self.setStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .not_staged_hunk => {
                self.setStatus("hunk is not staged", .{});
                return;
            },
            .binary_unsupported => {
                self.setStatus("binary hunk unstage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setStatus("hunk unstage supports modified files only", .{});
                return;
            },
            .patch_failed => {
                self.setStatus("could not build hunk patch", .{});
                return;
            },
        };

        var owned_patch = target.patch;
        errdefer if (owned_patch.len > 0) ctx.allocator().free(owned_patch);

        const pending = self.actions.begin(.unstage_hunk);
        errdefer _ = self.actions.finish(pending);

        const task = try ctx.allocator().create(UnstageHunkTask);
        task.* = .{
            .pending = pending,
            .repo_root = &.{},
            .path = &.{},
            .patch = &.{},
            .hunk_index = target.hunk_index,
            .mark_source = target.mark_source,
        };
        errdefer {
            if (task.repo_root.len > 0) ctx.allocator().free(task.repo_root);
            if (task.path.len > 0) ctx.allocator().free(task.path);
            if (task.patch.len > 0) ctx.allocator().free(task.patch);
            ctx.allocator().destroy(task);
        }

        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        task.path = try ctx.allocator().dupe(u8, target.path);
        task.patch = owned_patch;
        owned_patch = &.{};

        ctx.task().spawnWith(task, UnstageHunkTask.run) catch |err| {
            self.setStatus("could not start hunk unstage task", .{});
            return err;
        };
        self.setStatus("unstaging hunk: {s}", .{target.path});
    }

    const GitActionTargetKind = enum {
        file,
        directory,
    };

    const GitActionPath = struct {
        path: []const u8,
        kind: GitActionTargetKind,
    };

    const StageTarget = struct {
        repo_root: []const u8,
        path: []const u8,
        kind: GitActionTargetKind,
    };

    const StageTargetResult = union(enum) {
        ready: StageTarget,
        already_staged: []const u8,
        stale_status,
        conflict_unsupported: []const u8,
        no_stageable_content: []const u8,
        unavailable_source,
        no_repo,
        no_path,
    };

    const HunkStageTarget = struct {
        repo_root: []const u8,
        path: []const u8,
        hunk_index: usize,
        patch: []u8,
        mark_source: app_actions.HunkMarkSource = .session,
    };

    const HunkStageTargetResult = union(enum) {
        ready: HunkStageTarget,
        unavailable_source,
        no_repo,
        no_file,
        no_path,
        no_hunk,
        offscreen_cursor,
        stale_status,
        conflict_unsupported,
        binary_unsupported,
        unsupported_file_state,
        already_staged_hunk,
        patch_failed,
    };

    const HunkUnstageTarget = HunkStageTarget;

    const HunkUnstageTargetResult = union(enum) {
        ready: HunkUnstageTarget,
        unavailable_source,
        no_repo,
        no_file,
        no_path,
        no_hunk,
        offscreen_cursor,
        not_staged_hunk,
        binary_unsupported,
        unsupported_file_state,
        patch_failed,
    };

    fn selectedHunkStageTarget(self: *const App, allocator: std.mem.Allocator) HunkStageTargetResult {
        if (!diff_source.sourceAllowsStageAction(self.config.source)) return .unavailable_source;
        const repo_root = self.activeRepoRoot() orelse return .no_repo;
        if (self.activeCombinedProjection()) |bundle| {
            return self.selectedProjectedHunkStageTarget(allocator, repo_root, bundle);
        }
        const file = self.selectedFile() orelse return .no_file;
        const path = diff_file.canonicalPathKey(file) orelse return .no_path;
        if (!self.diffCursorIsVisible()) return .offscreen_cursor;
        const hunk_index = self.selectedHunkIndex() orelse return .no_hunk;
        if (file.hunks.len == 0 or hunk_index >= file.hunks.len) return .no_hunk;
        const entry = self.freshStatusEntryForPathKey(repo_root, path) orelse return .stale_status;
        if (entry.isConflict()) return .conflict_unsupported;
        if (file.is_binary) return .binary_unsupported;
        if (diff_file.status(file) != .modified or diff_file.hasModeChange(file)) return .unsupported_file_state;
        if (self.staged_hunks.contains(repo_root, path, hunk_index)) return .already_staged_hunk;

        const patch = diff_patch.formatSingleHunkPatch(allocator, file, hunk_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = hunk_index,
            .patch = patch,
        } };
    }

    fn selectedHunkUnstageTarget(self: *const App, allocator: std.mem.Allocator) HunkUnstageTargetResult {
        if (!diff_source.sourceAllowsUnstageAction(self.config.source)) return .unavailable_source;
        const repo_root = self.activeRepoRoot() orelse return .no_repo;
        if (self.activeCombinedProjection()) |bundle| {
            return self.selectedProjectedHunkUnstageTarget(allocator, repo_root, bundle);
        }
        const file = self.selectedFile() orelse return .no_file;
        const path = diff_file.canonicalPathKey(file) orelse return .no_path;
        if (!self.diffCursorIsVisible()) return .offscreen_cursor;
        const hunk_index = self.selectedHunkIndex() orelse return .no_hunk;
        if (file.hunks.len == 0 or hunk_index >= file.hunks.len) return .no_hunk;
        if (file.is_binary) return .binary_unsupported;
        if (diff_file.status(file) != .modified or diff_file.hasModeChange(file)) return .unsupported_file_state;
        if (!self.staged_hunks.contains(repo_root, path, hunk_index)) return .not_staged_hunk;

        // This reverses a session-staged hunk from the same loaded FileDiff.
        // finishStageHunk intentionally avoids a full diff reload, and
        // clearLoadedDiff clears staged_hunks before a new document can reuse
        // the same ordinal for a different hunk.
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, hunk_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = hunk_index,
            .patch = patch,
        } };
    }

    fn selectedProjectedHunkStageTarget(
        self: *const App,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        bundle: *const app_review_projection.CombinedHunkBundle,
    ) HunkStageTargetResult {
        const path = diff_file.canonicalPathKey(bundle.projection.file) orelse return .no_path;
        if (!self.diffCursorIsVisible()) return .offscreen_cursor;
        const projected_index = self.selectedHunkIndex() orelse return .no_hunk;
        if (projected_index >= bundle.projection.hunk_states.len) return .no_hunk;
        const state = bundle.projection.hunk_states[projected_index];
        const origin_index = switch (state.origin) {
            .unstaged => |index| index,
            .cached => return .already_staged_hunk,
        };
        const file = if (bundle.unstaged_bundle.loaded.document.files.len > 0)
            bundle.unstaged_bundle.loaded.document.files[0]
        else
            return .no_file;
        if (origin_index >= file.hunks.len) return .no_hunk;
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, origin_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = projected_index,
            .patch = patch,
            .mark_source = .projection,
        } };
    }

    fn selectedProjectedHunkUnstageTarget(
        self: *const App,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        bundle: *const app_review_projection.CombinedHunkBundle,
    ) HunkUnstageTargetResult {
        const path = diff_file.canonicalPathKey(bundle.projection.file) orelse return .no_path;
        if (!self.diffCursorIsVisible()) return .offscreen_cursor;
        const projected_index = self.selectedHunkIndex() orelse return .no_hunk;
        if (projected_index >= bundle.projection.hunk_states.len) return .no_hunk;
        const state = bundle.projection.hunk_states[projected_index];
        const origin_index = switch (state.origin) {
            .cached => |index| index,
            .unstaged => return .not_staged_hunk,
        };
        const file = if (bundle.cached_bundle.loaded.document.files.len > 0)
            bundle.cached_bundle.loaded.document.files[0]
        else
            return .no_file;
        if (origin_index >= file.hunks.len) return .no_hunk;
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, origin_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = projected_index,
            .patch = patch,
            .mark_source = .projection,
        } };
    }

    fn selectedStageTarget(self: *const App) StageTargetResult {
        if (!diff_source.sourceAllowsStageAction(self.config.source)) return .unavailable_source;
        const repo_root = self.activeRepoRoot() orelse return .no_repo;
        const action_target = self.selectedSidebarActionTarget() orelse return .no_path;
        return switch (action_target.kind) {
            .file => blk: {
                if (self.freshStatusEntryForPathKey(repo_root, action_target.path)) |entry| {
                    if (!entry.isConflict() and entry.isStaged() and !entry.isUnstaged()) return .{ .already_staged = action_target.path };
                }
                break :blk .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file } };
            },
            .directory => self.selectedDirectoryStageTarget(repo_root, action_target.path),
        };
    }

    fn unstageSelectedFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.selectedUnstageTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("unstage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .conflict_unsupported => |target_path| {
                if (target_path.kind == .directory) {
                    self.setStatus("conflict under directory: {s}", .{target_path.path});
                } else {
                    self.setStatus("conflict unstage is not supported yet", .{});
                }
                return;
            },
            .no_staged_content => |target_path| {
                if (target_path.kind == .directory) {
                    self.setStatus("no staged files under: {s}", .{target_path.path});
                } else {
                    self.setStatus("no staged content selected", .{});
                }
                return;
            },
        };

        try self.setPendingSelectionRestore(ctx.allocator(), target.path);
        errdefer self.clearPendingSelectionRestore(ctx.allocator());

        const pending = self.actions.begin(.unstage_file);
        errdefer _ = self.actions.finish(pending);

        const task = try ctx.allocator().create(UnstageFileTask);
        task.* = .{
            .pending = pending,
            .repo_root = &.{},
            .path = &.{},
        };
        errdefer {
            if (task.repo_root.len > 0) ctx.allocator().free(task.repo_root);
            if (task.path.len > 0) ctx.allocator().free(task.path);
            ctx.allocator().destroy(task);
        }

        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        task.path = try ctx.allocator().dupe(u8, target.path);

        ctx.task().spawnWith(task, UnstageFileTask.run) catch |err| {
            self.setStatus("could not start unstage task", .{});
            return err;
        };
        self.setStatus("unstaging: {s}", .{target.path});
    }

    const UnstageTarget = struct {
        repo_root: []const u8,
        path: []const u8,
        kind: GitActionTargetKind,
    };

    const UnstageTargetResult = union(enum) {
        ready: UnstageTarget,
        unavailable_source,
        no_repo,
        no_path,
        stale_status,
        conflict_unsupported: GitActionPath,
        no_staged_content: GitActionPath,
    };

    fn selectedUnstageTarget(self: *const App) UnstageTargetResult {
        if (!diff_source.sourceAllowsUnstageAction(self.config.source)) return .unavailable_source;
        const repo_root = self.activeRepoRoot() orelse return .no_repo;
        const action_target = self.selectedSidebarActionTarget() orelse return .no_path;
        if (self.status_load_pending != null) return .stale_status;
        const snapshot_root = self.git_status.repo_root orelse return .stale_status;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return .stale_status;
        return switch (action_target.kind) {
            .file => blk: {
                const entry = self.statusEntryForPathKey(action_target.path) orelse return .{ .no_staged_content = action_target };
                if (entry.isConflict()) return .{ .conflict_unsupported = action_target };
                if (!entry.isStaged()) return .{ .no_staged_content = action_target };
                break :blk .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file } };
            },
            .directory => self.selectedDirectoryUnstageTarget(repo_root, action_target.path),
        };
    }

    fn requestDiscardSelectedFile(self: *App, allocator: std.mem.Allocator) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.selectedDiscardTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("discard unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .directory_unsupported => {
                self.setStatus("directory discard is not supported yet", .{});
                return;
            },
            .conflict_unsupported => {
                self.setStatus("conflict discard is not supported yet", .{});
                return;
            },
            .untracked_unsupported => {
                self.setStatus("untracked discard is not supported yet", .{});
                return;
            },
            .no_unstaged_content => {
                self.setStatus("no unstaged changes selected", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        const owned_repo_root = try allocator.dupe(u8, target.repo_root);
        errdefer allocator.free(owned_repo_root);
        const owned_path = try allocator.dupe(u8, target.path);
        errdefer allocator.free(owned_path);

        self.discard_confirmation = .{
            .repo_root = owned_repo_root,
            .path = owned_path,
        };
        self.overlay.openDiscardFile();
    }

    fn confirmDiscardFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const confirmation = self.discard_confirmation orelse return;
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }

        try self.setPendingSelectionRestore(ctx.allocator(), confirmation.path);
        errdefer self.clearPendingSelectionRestore(ctx.allocator());

        const pending = self.actions.begin(.discard_file);
        errdefer _ = self.actions.finish(pending);

        const task = try ctx.allocator().create(DiscardFileTask);
        task.* = .{
            .pending = pending,
            .repo_root = &.{},
            .path = &.{},
        };
        errdefer {
            if (task.repo_root.len > 0) ctx.allocator().free(task.repo_root);
            if (task.path.len > 0) ctx.allocator().free(task.path);
            ctx.allocator().destroy(task);
        }

        task.repo_root = try ctx.allocator().dupe(u8, confirmation.repo_root);
        task.path = try ctx.allocator().dupe(u8, confirmation.path);

        ctx.task().spawnWith(task, DiscardFileTask.run) catch |err| {
            self.setStatus("could not start discard task", .{});
            return err;
        };

        self.setStatus("discarding: {s}", .{confirmation.path});
        self.cancelDiscardConfirmation(ctx.allocator());
    }

    fn cancelDiscardConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.discard_confirmation = null;
        if (self.overlay.isDiscardFile()) self.overlay.close();
    }

    const DiscardTarget = struct {
        repo_root: []const u8,
        path: []const u8,
    };

    const DiscardTargetResult = union(enum) {
        ready: DiscardTarget,
        unavailable_source,
        no_repo,
        no_path,
        stale_status,
        directory_unsupported,
        conflict_unsupported,
        untracked_unsupported,
        no_unstaged_content,
    };

    fn selectedDiscardTarget(self: *const App) DiscardTargetResult {
        if (!diff_source.sourceAllowsStageAction(self.config.source)) return .unavailable_source;
        const repo_root = self.activeRepoRoot() orelse return .no_repo;
        const action_target = self.selectedSidebarActionTarget() orelse return .no_path;
        if (action_target.kind == .directory) return .directory_unsupported;
        const entry = self.freshStatusEntryForPathKey(repo_root, action_target.path) orelse return .stale_status;
        if (entry.isConflict()) return .conflict_unsupported;
        return switch (file_tree.stagePresenceFromEntry(entry)) {
            .unstaged_only, .mixed => .{ .ready = .{ .repo_root = repo_root, .path = action_target.path } },
            .untracked => .untracked_unsupported,
            .staged_only, .clean_or_unknown, .conflict => .no_unstaged_content,
        };
    }

    fn enterCommitPanelMode(self: *App, mode: app_commit_panel.Mode) void {
        if (self.actions.pending != null) {
            self.setStatus("finish current git action before committing", .{});
            return;
        }
        if (!diff_source.sourceAllowsStageProjection(self.config.source) or self.activeRepoRoot() == null) {
            self.setStatus("commit unavailable for this source", .{});
            return;
        }

        self.cancelDiscardConfirmation(self.allocator.?);
        self.cancelAmendConfirmation(self.allocator.?);
        self.overlay.close();
        self.commit_panel.open(mode);
    }

    fn submitCommitPanel(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.commit_panel.commit_error = .action_pending;
            self.setStatus("finish current git action before committing", .{});
            return;
        }

        if (self.commit_panel.validateSubmit(self.stagedSummaryForActiveRepo())) |err| {
            self.commit_panel.commit_error = err;
            return;
        }

        const repo_root = self.activeRepoRoot() orelse {
            self.commit_panel.commit_error = .status_unavailable;
            self.setStatus("commit unavailable for this source", .{});
            return;
        };

        if (self.commit_panel.mode == .amend) {
            try self.openAmendConfirmation(ctx.allocator(), repo_root);
            return;
        }

        try self.startCommitTask(ctx, repo_root);
    }

    fn startCommitTask(self: *App, ctx: *chasen.Ctx(Msg), repo_root: []const u8) !void {
        var parts = self.commit_panel.formatMessageParts(ctx.allocator()) catch {
            self.commit_panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(ctx.allocator());

        const owned_root = try ctx.allocator().dupe(u8, repo_root);
        errdefer ctx.allocator().free(owned_root);

        const task = try ctx.allocator().create(CommitTask);
        errdefer ctx.allocator().destroy(task);

        const pending = self.actions.begin(.commit);
        task.* = .{
            .pending = pending,
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        parts = .{ .subject = &.{}, .body = null };

        ctx.task().spawnWith(task, CommitTask.run) catch |err| {
            self.actions.clear();
            ctx.allocator().free(task.subject);
            if (task.body) |body| ctx.allocator().free(body);
            self.commit_panel.commit_error = .commit_failed;
            self.setStatus("could not start commit task", .{});
            return err;
        };

        self.setStatus("committing...", .{});
    }

    fn openAmendConfirmation(self: *App, allocator: std.mem.Allocator, repo_root: []const u8) !void {
        var parts = self.commit_panel.formatMessageParts(allocator) catch {
            self.commit_panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(allocator);

        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        self.amend_confirmation = .{
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        parts = .{ .subject = &.{}, .body = null };
        self.overlay.openAmendCommit();
    }

    fn confirmAmend(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.actions.pending != null) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var confirmation = self.amend_confirmation orelse return;
        self.amend_confirmation = null;
        errdefer confirmation.deinit(ctx.allocator());

        const task = try ctx.allocator().create(AmendTask);
        errdefer ctx.allocator().destroy(task);

        const pending = self.actions.begin(.amend);
        errdefer _ = self.actions.finish(pending);

        task.* = .{
            .pending = pending,
            .repo_root = confirmation.repo_root,
            .subject = confirmation.subject,
            .body = confirmation.body,
        };
        confirmation = .{ .repo_root = &.{}, .subject = &.{}, .body = null };

        ctx.task().spawnWith(task, AmendTask.run) catch |err| {
            self.actions.clear();
            ctx.allocator().free(task.repo_root);
            ctx.allocator().free(task.subject);
            if (task.body) |body| ctx.allocator().free(body);
            if (self.overlay.isAmendCommit()) self.overlay.close();
            self.commit_panel.commit_error = .amend_failed;
            self.setStatus("could not start amend task", .{});
            return err;
        };

        self.overlay.close();
        self.setStatus("amending...", .{});
    }

    fn cancelAmendConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.amend_confirmation = null;
        if (self.overlay.isAmendCommit()) self.overlay.close();
    }

    pub fn stagedSummaryForActiveRepo(self: *const App) app_commit_panel.StagedSummary {
        if (!diff_source.sourceAllowsStageProjection(self.config.source)) return .unavailable;

        const active_root = self.activeRepoRoot() orelse return .unavailable;
        if (self.status_load_pending != null) return .loading_or_stale;
        const snapshot_root = self.git_status.repo_root orelse return .unavailable;
        if (!std.mem.eql(u8, active_root, snapshot_root)) return .loading_or_stale;

        var count: usize = 0;
        for (self.git_status.document.entries) |entry| {
            if (entry.isStaged()) count += 1;
        }
        return .{ .ready = .{ .count = count } };
    }

    fn finishStageFile(self: *App, ctx: *chasen.Ctx(Msg), finished: StageFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                self.setStatus("staged: {s}", .{result.path});
                try self.reloadAfterGitAction(ctx);
            },
            .failed => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("stage failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("stage failed: {s}", .{message});
            },
        }
    }

    fn finishStageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: StageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                const active_root = self.activeRepoRoot();
                const active_matches = active_root != null and std.mem.eql(u8, active_root.?, result.repo_root);
                self.setStatus("staged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
                if (active_matches) {
                    if (result.mark_source == .session) {
                        try self.staged_hunks.add(ctx.allocator(), result.repo_root, result.path, result.hunk_index);
                    }
                    self.startStatusLoad(ctx, result.repo_root);
                }
            },
            .failed => |message| {
                self.setStatus("hunk stage failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.setStatus("hunk stage failed: {s}", .{message});
            },
        }
    }

    fn finishUnstageFile(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                self.setStatus("unstaged: {s}", .{result.path});
                try self.reloadAfterGitAction(ctx);
            },
            .failed => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("unstage failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("unstage failed: {s}", .{message});
            },
        }
    }

    fn finishUnstageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                const active_root = self.activeRepoRoot();
                const active_matches = active_root != null and std.mem.eql(u8, active_root.?, result.repo_root);
                self.setStatus("unstaged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
                if (active_matches) {
                    if (result.mark_source == .session) {
                        _ = self.staged_hunks.remove(ctx.allocator(), result.repo_root, result.path, result.hunk_index);
                    }
                    self.startStatusLoad(ctx, result.repo_root);
                }
            },
            .failed => |message| {
                self.setStatus("hunk unstage failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.setStatus("hunk unstage failed: {s}", .{message});
            },
        }
    }

    fn finishDiscardFile(self: *App, ctx: *chasen.Ctx(Msg), finished: DiscardFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                self.reviewed_store.clearPathKey(ctx.allocator(), result.repo_root, result.path) catch {
                    self.setStatus("discarded: {s}; could not clear reviewed mark", .{result.path});
                    try self.reloadAfterGitAction(ctx);
                    return;
                };
                self.setStatus("discarded: {s}", .{result.path});
                try self.reloadAfterGitAction(ctx);
            },
            .failed => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("discard failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("discard failed: {s}", .{message});
            },
        }
    }

    fn finishCommit(self: *App, ctx: *chasen.Ctx(Msg), finished: CommitFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                const reviewed_clear_failed = if (self.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                const active_root = self.activeRepoRoot();
                const active_matches = active_root != null and std.mem.eql(u8, active_root.?, result.repo_root);
                self.commit_panel.close();

                if (active_matches) {
                    if (reviewed_clear_failed) {
                        self.setStatus("committed; could not clear reviewed marks", .{});
                    } else {
                        self.setStatus("committed", .{});
                    }
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, false);
                } else {
                    if (reviewed_clear_failed) {
                        self.setStatus("committed: {s}; could not clear reviewed marks", .{result.repo_root});
                    } else {
                        self.setStatus("committed: {s}", .{result.repo_root});
                    }
                }
            },
            .failed => |message| {
                self.commit_panel.commit_error = .commit_failed;
                self.setStatus("commit failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.commit_panel.commit_error = .commit_failed;
                self.setStatus("commit failed: {s}", .{message});
            },
        }
    }

    fn finishAmend(self: *App, ctx: *chasen.Ctx(Msg), finished: AmendFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok => {
                const reviewed_clear_failed = if (self.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                const active_root = self.activeRepoRoot();
                const active_matches = active_root != null and std.mem.eql(u8, active_root.?, result.repo_root);
                self.commit_panel.close();
                self.cancelAmendConfirmation(ctx.allocator());

                if (active_matches) {
                    if (reviewed_clear_failed) {
                        self.setStatus("amended; could not clear reviewed marks", .{});
                    } else {
                        self.setStatus("amended", .{});
                    }
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, false);
                } else {
                    if (reviewed_clear_failed) {
                        self.setStatus("amended: {s}; could not clear reviewed marks", .{result.repo_root});
                    } else {
                        self.setStatus("amended: {s}", .{result.repo_root});
                    }
                }
            },
            .failed => |message| {
                self.commit_panel.commit_error = .amend_failed;
                self.setStatus("amend failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.commit_panel.commit_error = .amend_failed;
                self.setStatus("amend failed: {s}", .{message});
            },
        }
    }

    fn reloadAfterGitAction(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (diff_source.sourceIsOneShotInput(self.config.source)) {
            ctx.redraw().skip();
            return;
        }
        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx);
            return;
        }
        try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
            ctx.redraw().skip();
            return;
        }, false);
    }

    fn openSelectedFileInEditor(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const repo_root = self.activeRepoRoot() orelse {
            self.setStatus("editor unavailable for this source", .{});
            return;
        };
        const file = self.selectedFile() orelse {
            self.setStatus("no file selected", .{});
            return;
        };
        const target_path = diff_file.editorPath(file) orelse {
            self.setStatus("deleted files cannot be opened", .{});
            return;
        };

        var argv_buf: [editor.max_argv][]const u8 = undefined;
        const argv = editor.argv(self.env_map, target_path, &argv_buf);
        if (argv.len == 0) {
            self.setStatus("editor command is empty", .{});
            return;
        }

        _ = ctx.terminal().runForegroundCommand(.{
            .argv = argv,
            .cwd = repo_root,
            .finished = editorDone,
        }) catch |err| switch (err) {
            error.ForegroundCommandLimitExceeded => {
                self.setStatus("editor command already queued", .{});
                return;
            },
            error.ForegroundCommandEmptyArgv => {
                self.setStatus("editor command is empty", .{});
                return;
            },
            else => return err,
        };
        self.setStatus("opening editor: {s}", .{target_path});
    }

    fn finishEditorCommand(self: *App, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        switch (result.outcome) {
            .exited => |code| {
                if (code == 0) {
                    self.setStatus("editor closed", .{});
                } else {
                    self.setStatus("editor exited: {d}", .{code});
                }
            },
            .signaled => |signal| self.setStatus("editor signal: {d}", .{signal}),
            .spawn_failed => |err| self.setStatus("editor spawn failed: {s}", .{err}),
            .wait_failed => |err| self.setStatus("editor wait failed: {s}", .{err}),
        }

        if (diff_source.sourceIsOneShotInput(self.config.source)) {
            ctx.redraw().skip();
            return;
        }
        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx);
        } else {
            try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
                ctx.redraw().skip();
                return;
            }, self.load.state == .idle);
        }
    }

    fn editorDone(result: chasen.ForegroundCommandResult) Msg {
        return .{ .editor_finished = result };
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status.set(fmt, args);
    }

    pub fn exportInitialSelectionContextJson(allocator: std.mem.Allocator, io: std.Io, config: CliConfig, writer: *std.Io.Writer) !void {
        var discovery: ?repo_discovery.DiscoveryResult = null;
        defer if (discovery) |*result| result.deinit(allocator);

        const repo_root = if (diff_source.sourceRequiresRepo(config.source)) blk: {
            discovery = try repo_discovery.discover(allocator, io);
            const discovered_root = try activeRootFromDiscovery(discovery.?);
            break :blk discovered_root orelse return error.MissingRepoRoot;
        } else null;

        var load_result = app_load.runLoad(.{ .source = config.source, .repo_root = repo_root }, allocator, io);
        defer load_result.deinit(allocator);

        const selection = switch (load_result) {
            .empty => initialSelectionContext(config.source, repo_root, null),
            .loaded => |*bundle| initialSelectionContext(config.source, repo_root, &bundle.loaded),
            .failed, .failed_static => return error.ExportContextLoadFailed,
        };

        try context_export.writeSelectionContext(writer, selection);
    }

    fn activeRootFromDiscovery(discovery: repo_discovery.DiscoveryResult) !?[]const u8 {
        return switch (discovery) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => error.AmbiguousWorkspaceExport,
            .none => null,
        };
    }

    fn initialSelectionContext(source: SourceMode, repo_root: ?[]const u8, loaded: ?*const LoadedDiff) context.SelectionContext {
        return .{
            .repo_root = repo_root,
            .source = sourceContext(source),
            .selected = if (loaded) |active_loaded| initialSelection(active_loaded) else null,
        };
    }

    fn initialSelection(loaded: *const LoadedDiff) ?context.Selection {
        if (loaded.document.files.len == 0) return null;
        const file = loaded.document.files[0];
        return .{ .diff_file = .{
            .file_index = 0,
            .display_path = diff_file.displayPath(file),
            .path_key = diff_file.canonicalPathKey(file),
            .hunk_index = if (file.hunks.len > 0) 0 else null,
        } };
    }

    fn autoReloadTick(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (!self.config.watch) return;
        if (diff_source.sourceIsOneShotInput(self.config.source)) return;
        if (self.repo_picker.mode or self.search.mode or self.file_search.mode or self.commit_panel.is_open) {
            ctx.redraw().skip();
            return;
        }
        if (self.load.hasPending() or self.load.state == .loading) {
            ctx.redraw().skip();
            return;
        }

        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx);
        } else {
            try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
                ctx.redraw().skip();
                return;
            }, self.load.state == .idle);
        }
    }

    fn repoRootForCurrentSource(self: *const App) error{MissingRepoRoot}!?[]const u8 {
        if (!diff_source.sourceRequiresRepo(self.config.source)) return null;
        return self.activeRepoRoot() orelse error.MissingRepoRoot;
    }

    fn activeRepoRoot(self: *const App) ?[]const u8 {
        return self.repo_state.activeRoot();
    }

    fn needsRepoDiscovery(self: *const App) bool {
        return self.repo_state.needsDiscovery();
    }

    fn finishDiffLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: DiffLoadFinished) !void {
        if (self.allocator == null) self.allocator = ctx.allocator();

        var result = finished.result;
        defer result.deinit(ctx.allocator());
        var can_project_status = false;

        // Multiple reloads can be in flight. Only the newest generation is
        // allowed to update visible state.
        _ = self.load.finishPending(.{ .diff_load = finished.generation });
        if (!self.load.isCurrent(finished.generation)) return;

        // Capture this before clearLoadedDiff(): the previous loaded session is
        // what distinguishes first load from reload/restore paths.
        const had_loaded_before = self.activeLoadedDiffConst() != null;
        const had_pending_restore = self.pending_selection_restore != null;
        self.clearLoadedDiff();

        switch (result) {
            .empty => {
                self.load.replaceEmpty(ctx.allocator(), .no_changes);
                can_project_status = true;
            },
            .loaded => |*bundle| {
                var loaded = bundle.loaded;
                var arena = bundle.takeArena();
                errdefer arena.deinit();

                try self.materializeReviewedFiles(ctx.allocator(), &loaded);
                errdefer ctx.allocator().free(loaded.reviewed_files);

                if (self.review_display.hide_reviewed_files or self.review_display.changed_file_filter != .all) {
                    try loaded.rebuildVisibleNodes(arena.allocator(), self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
                }

                // Keep all fallible setup above this point. After assigning a
                // LoadedSession, LoadRuntimeState owns both the arena and the
                // materialized reviewed slice.
                self.load.replaceLoaded(ctx.allocator(), .{
                    .arena = arena,
                    .loaded = loaded,
                    .reviewed_files_owned = true,
                });

                const active_loaded = self.activeLoadedDiff().?;
                if (!had_loaded_before and !had_pending_restore) {
                    self.selectFirstVisibleFile(active_loaded);
                } else {
                    self.syncSidebarNodeToSelectedFile(active_loaded);
                }
                self.clampSelection(active_loaded.document.files.len);
                if (self.review_display.hide_reviewed_files) {
                    self.reconcileSelectionAfterVisibleNodeChange(active_loaded);
                }
                self.clampDiffNavigation();
                self.refreshSearchForSelectedFile();
                can_project_status = true;
            },
            .failed => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                try self.storeFailedMessage(ctx.allocator(), std.mem.trim(u8, message, " \t\r\n"));
            },
            .failed_static => |message| {
                self.clearPendingSelectionRestore(ctx.allocator());
                try self.storeFailedMessage(ctx.allocator(), message);
            },
        }

        // Diff and status loads run independently. Re-apply the status overlay
        // here so the final sidebar does not depend on which task finished
        // first.
        const prefer_first_visible_file = !had_loaded_before and !had_pending_restore;
        if (prefer_first_visible_file and self.status_load_pending != null) {
            self.pending_initial_first_visible_selection = true;
        }
        if (can_project_status) try self.applyStatusProjection(ctx.allocator(), prefer_first_visible_file);
    }

    fn finishStatusLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: StatusLoadFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (result.generation != self.status_load_generation) return;
        if (self.status_load_pending == result.generation) self.status_load_pending = null;

        switch (result.result) {
            .empty => {
                self.git_status.clear();
                const prefer_first_visible_file = self.pending_initial_first_visible_selection;
                self.pending_initial_first_visible_selection = false;
                try self.applyStatusProjection(ctx.allocator(), prefer_first_visible_file);
            },
            .loaded => |*bundle| {
                try self.git_status.replace(result.repo_root, bundle);
                result.result = .empty;
                const prefer_first_visible_file = self.pending_initial_first_visible_selection;
                self.pending_initial_first_visible_selection = false;
                try self.applyStatusProjection(ctx.allocator(), prefer_first_visible_file);
            },
            .failed => |message| {
                self.git_status.clear();
                self.pending_initial_first_visible_selection = false;
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("status load failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.git_status.clear();
                self.pending_initial_first_visible_selection = false;
                self.clearPendingSelectionRestore(ctx.allocator());
                self.setStatus("status load failed: {s}", .{message});
            },
        }
    }

    fn finishReviewProjectionLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: ReviewProjectionFinished) !void {
        var result = finished;
        var consumed = false;
        defer if (!consumed) result.deinit(ctx.allocator());

        const pending_id = switch (self.review_projection) {
            .pending => |request| request.id,
            else => return,
        };
        if (pending_id != result.request.id) return;

        const current = self.reviewProjectionTarget() orelse return;
        if (!result.request.matchesBorrowed(
            current.repo_root,
            current.path_key,
            current.kind,
            current.source_kind,
            self.load.generation,
            self.status_load_generation,
        )) return;

        self.review_projection.deinit(ctx.allocator());
        switch (result.result) {
            .ready => |ready| {
                self.review_projection = .{ .ready = .{
                    .request = result.request,
                    .value = ready,
                } };
                consumed = true;
            },
            .failed => |body| {
                self.review_projection = .{ .failed = .{
                    .request = result.request,
                    .body = body,
                } };
                consumed = true;
            },
            .failed_static => |message| {
                var request = try app_review_projection.cloneRequest(
                    ctx.allocator(),
                    result.request.id,
                    result.request.repo_root,
                    result.request.path_key,
                    result.request.kind,
                    result.request.source_kind,
                    result.request.load_generation,
                    result.request.status_generation,
                );
                errdefer request.deinit(ctx.allocator());

                var body = try app_review_projection.statusBodyAlloc(ctx.allocator(), result.request.path_key, "{s}", .{message});
                errdefer body.deinit(ctx.allocator());

                self.review_projection = .{ .failed = .{
                    .request = request,
                    .body = body,
                } };
            },
        }
    }

    fn applyStatusProjection(self: *App, allocator: std.mem.Allocator, prefer_first_visible_file: bool) !void {
        if (!diff_source.sourceAllowsStageProjection(self.config.source)) return;

        const status_document = self.git_status.document;
        if (status_document.entries.len == 0) {
            if (self.pending_selection_restore != null and
                (self.load.hasPending() or self.status_load_pending != null)) return;
            if (self.activeLoadedDiff()) |loaded| {
                if (self.restorePendingSelectionByPath(allocator, loaded)) return;
            }
            self.clearPendingSelectionRestore(allocator);
            return;
        }

        if (self.activeLoadedDiff()) |loaded| {
            try self.rebuildLoadedTreeWithStatus(allocator, loaded, prefer_first_visible_file);
            return;
        }

        switch (self.load.state) {
            .empty => |reason| if (reason == .no_changes and
                file_tree.statusOnlyEntryCount(status_document, .{ .files = &.{} }) > 0)
            {
                try self.createStatusOnlyLoadedSession(allocator, status_document);
            },
            else => {},
        }
    }

    fn rebuildLoadedTreeWithStatus(self: *App, app_allocator: std.mem.Allocator, loaded: *LoadedDiff, prefer_first_visible_file: bool) !void {
        const allocator = self.loadArenaAllocator() orelse return;
        try self.ensureTreeOrderScope(app_allocator);
        loaded.tree = try file_tree.buildWithStatusStable(allocator, loaded.document, self.git_status.document, self.stableOrderOptions(app_allocator));
        try loaded.rebuildVisibleNodes(allocator, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
        // Status can finish before the diff reload triggered by a Git action.
        // In that case this projection is over the old diff, so keep the
        // pending path restore for the incoming loaded diff.
        if (self.pending_selection_restore != null and self.load.hasPending()) return;
        if (prefer_first_visible_file) {
            self.selectFirstVisibleFile(loaded);
        } else if (!self.restorePendingSelectionOrFallback(app_allocator, loaded)) {
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
        }
    }

    fn createStatusOnlyLoadedSession(self: *App, allocator: std.mem.Allocator, status_document: git_status.StatusDocument) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const document = diff_parser.DiffDocument{ .files = &.{} };
        try self.ensureTreeOrderScope(allocator);
        var loaded: LoadedDiff = .{
            .text = "",
            .document = document,
            .tree = try file_tree.buildWithStatusStable(arena_allocator, document, status_document, self.stableOrderOptions(allocator)),
            .rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document),
            .collapsed_hunks = &.{},
            .collapsed_dirs = .empty,
            .bytes = 0,
            .lines = 0,
        };
        try loaded.rebuildVisibleNodes(arena_allocator, false, self.review_display.changed_file_filter);

        self.load.replaceLoaded(allocator, .{
            .arena = arena,
            .loaded = loaded,
            .reviewed_files_owned = false,
        });

        const active_loaded = self.activeLoadedDiff().?;
        var visible_index: usize = 0;
        while (visible_index < active_loaded.visibleNodeCount()) : (visible_index += 1) {
            const node_index = active_loaded.visibleNodeAt(visible_index) orelse continue;
            if (active_loaded.tree.nodes[node_index].target == .directory) continue;
            self.viewer.selected_node = node_index;
            self.selectSidebarNode(active_loaded, node_index);
            break;
        }
        _ = self.restorePendingSelectionOrFallback(allocator, active_loaded);
    }

    fn storeFailedMessage(self: *App, allocator: std.mem.Allocator, message: []const u8) !void {
        try self.load.replaceFailed(allocator, message);
    }

    fn clearLoadedDiff(self: *App) void {
        self.load.clearCurrent(self.allocator);
        if (self.allocator) |allocator| {
            self.review_projection.deinit(allocator);
            self.staged_hunks.clear(allocator);
        }
        self.viewer.diff_scroll = 0;
        self.viewer.diff_horizontal_scroll = 0;
        self.viewer.diff_cursor = .{ .metadata = 0 };
        self.clearSearchMatch();
    }

    fn selectFileDelta(self: *App, delta: i2) void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (loaded.tree.nodes.len == 0 or loaded.visibleNodeCount() == 0) return;

        if (delta < 0) {
            if (loaded.previousVisibleNodeIndex(self.viewer.selected_node)) |previous| {
                self.selectSidebarNode(loaded, previous);
            }
        } else if (loaded.nextVisibleNodeIndex(self.viewer.selected_node)) |next| {
            self.selectSidebarNode(loaded, next);
        }
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    fn selectFileAbsolute(self: *App, index: usize) void {
        const file_count = self.loadedFileCount() orelse return;
        if (file_count == 0) return;
        const target = @min(index, file_count - 1);
        if (self.selectedDiffFileTarget() == target) {
            if (self.activeLoadedDiff()) |loaded| {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            self.clampSelection(file_count);
            return;
        }
        self.setSelectedDiffFile(target);
        if (self.activeLoadedDiff()) |loaded| {
            self.syncSidebarNodeToSelectedFile(loaded);
        }
        self.resetDiffPosition();
        self.refreshSearchForSelectedFile();
        self.clampSelection(file_count);
        self.clampDiffNavigation();
    }

    fn selectLastFile(self: *App) void {
        const file_count = self.loadedFileCount() orelse return;
        if (file_count == 0) return;
        self.selectFileAbsolute(file_count - 1);
    }

    fn selectSidebarNode(self: *App, loaded: *LoadedDiff, node_index: usize) void {
        if (node_index >= loaded.tree.nodes.len) return;
        const previous_file = self.selectedDiffFileTarget();
        self.viewer.selected_node = node_index;
        // File rows change the active diff pane file. Directory rows only move
        // the sidebar cursor and keep the previous selected target visible.
        switch (loaded.tree.nodes[node_index].target) {
            .diff_file => |file_index| {
                self.setSelectedDiffFile(file_index);
                if (previous_file == null or file_index != previous_file.?) {
                    self.resetDiffPosition();
                    self.refreshSearchForSelectedFile();
                }
            },
            .status_entry => |status_index| {
                self.viewer.selected_target = .{ .status_only = status_index };
                self.resetDiffPosition();
                self.clearSearchMatch();
            },
            .directory => {},
        }
    }

    fn toggleSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind != .directory) return;
        const allocator = self.loadArenaAllocator() orelse return;
        try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(allocator, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn clickSidebarNode(self: *App, node_index: usize) !void {
        if (self.viewer.sidebar_hidden) return;
        const loaded = self.activeLoadedDiff() orelse return;
        if (node_index >= loaded.tree.nodes.len) return;

        self.viewer.focus = .sidebar;
        self.selectSidebarNode(loaded, node_index);

        const node = loaded.tree.nodes[node_index];
        if (node.kind == .directory) try self.toggleSelectedDirectory();

        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    fn expandSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind != .directory) return;
        file_tree.expand(&loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn collapseOrSelectParentDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind == .directory and !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) {
            const allocator = self.loadArenaAllocator() orelse return;
            try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path);
            try loaded.rebuildVisibleNodes(allocator, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
            self.clampSelection(loaded.document.files.len);
            return;
        }
        if (loaded.tree.parentDirectoryNodeIndex(self.viewer.selected_node)) |parent| {
            self.viewer.selected_node = parent;
            self.clampSelection(loaded.document.files.len);
        }
    }

    fn scrollDiff(self: *App, delta: i2) void {
        const old_scroll = self.viewer.diff_scroll;
        const old_cursor_offset = self.selectedDiffCursorOffset();
        if (delta < 0) {
            self.viewer.diff_scroll -|= 1;
        } else {
            self.viewer.diff_scroll += 1;
        }
        self.clampDiffNavigation();
        self.syncDiffCursorAfterViewportScroll(delta, old_scroll, old_cursor_offset);
    }

    fn scrollDiffHorizontal(self: *App, delta: i2) void {
        const step: usize = 8;
        if (delta < 0) {
            self.viewer.diff_horizontal_scroll -|= step;
        } else {
            self.viewer.diff_horizontal_scroll += step;
            self.clampDiffHorizontalScrollToVisibleRows();
        }
    }

    fn clampDiffHorizontalScrollToVisibleRows(self: *App) void {
        const max_scroll = self.visibleBodyTextMaxHorizontalScroll();
        if (self.viewer.diff_horizontal_scroll > max_scroll) {
            self.viewer.diff_horizontal_scroll = max_scroll;
        }
    }

    fn visibleBodyTextMaxHorizontalScroll(self: *const App) usize {
        const file = self.selectedFile() orelse return 0;
        const mode = self.effectiveDisplayMode();
        const visible_rows = self.diffVisibleRows();
        if (visible_rows == 0) return 0;

        const pane_width = self.diffPaneWidth();
        const line_index = self.selectedFileCachedLineIndex(mode);
        var max_scroll: usize = 0;
        var rows = if (line_index) |index|
            diff_view_model.BodyRowIterator.initAtWithFolded(file, mode, index, self.viewer.diff_scroll, self.selectedFoldedHunks())
        else
            diff_view_model.BodyRowIterator.initWithFolded(file, mode, self.selectedFoldedHunks());
        var skipped: usize = if (line_index != null) self.viewer.diff_scroll else 0;
        var visible: usize = 0;
        while (rows.next()) |body_row| {
            if (skipped < self.viewer.diff_scroll) {
                skipped += 1;
                continue;
            }
            if (visible >= visible_rows) break;
            visible += 1;
            max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(body_row, pane_width, self.viewer.view_options.line_numbers));
        }
        return max_scroll;
    }

    fn pageDiff(self: *App, delta: i2) void {
        const rows = self.diffVisibleRows();
        const step: usize = @max(rows, 1);
        if (delta < 0) {
            self.viewer.diff_scroll -|= step;
        } else {
            self.viewer.diff_scroll += step;
        }
        self.clampDiffNavigation();
    }

    fn moveDiffCursorRows(self: *App, delta: i2) void {
        const current = self.selectedDiffCursorOffset() orelse {
            self.initializeDiffCursorForSelectedFile();
            self.applyDiffCursorScrolloff();
            return;
        };
        const line_count = self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const target = if (delta < 0) current -| 1 else @min(current + 1, line_count - 1);
        self.viewer.diff_cursor = self.selectedCoordinateAtOffset(target) orelse self.viewer.diff_cursor;
        self.applyDiffCursorScrolloff();
    }

    fn moveDiffCursorPage(self: *App, delta: i2) void {
        const current = self.selectedDiffCursorOffset() orelse {
            self.initializeDiffCursorForSelectedFile();
            self.applyDiffCursorScrolloff();
            return;
        };
        const line_count = self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const step = @max(self.diffVisibleRows(), 1);
        const target = if (delta < 0) current -| step else @min(current + step, line_count - 1);
        self.viewer.diff_cursor = self.selectedCoordinateAtOffset(target) orelse self.viewer.diff_cursor;
        self.applyDiffCursorScrolloff();
    }

    fn selectHunkDelta(self: *App, delta: i2) void {
        const file = self.selectedFile() orelse return;
        if (file.hunks.len == 0) return;

        const current = self.selectedHunkIndex();
        const target = if (delta < 0) blk: {
            if (current) |hunk_index| {
                if (self.viewer.diff_cursor == .hunk_line) break :blk hunk_index;
                break :blk hunk_index -| 1;
            }
            break :blk 0;
        } else blk: {
            if (current) |hunk_index| break :blk @min(hunk_index + 1, file.hunks.len - 1);
            break :blk 0;
        };
        self.viewer.diff_cursor = .{ .hunk_header = target };
        self.applyDiffCursorScrolloff();
    }

    fn toggleSelectedHunkFold(self: *App) void {
        if (self.activeCombinedProjection() != null) {
            self.setStatus("hunk fold is unavailable for mixed staged/unstaged view", .{});
            return;
        }
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.document.files.len) return;
        const file = loaded.document.files[file_index];
        const hunk_index = self.selectedHunkIndex() orelse return;
        if (hunk_index >= file.hunks.len) return;

        if (!loaded.isHunkFolded(file_index, hunk_index) and
            self.currentSearchMatchInHunkBody(hunk_index))
        {
            return;
        }

        const folding = !loaded.isHunkFolded(file_index, hunk_index);
        loaded.toggleHunkFold(file_index, hunk_index);
        if (folding) {
            switch (self.viewer.diff_cursor) {
                .hunk_line => |line| if (line.hunk_index == hunk_index) {
                    self.viewer.diff_cursor = .{ .hunk_header = hunk_index };
                },
                else => {},
            }
        }
        self.updateSearchMatchOffset();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    fn scrollSelectedHunkIntoView(self: *App) void {
        const mode = self.effectiveDisplayMode();
        const hunk_index = self.selectedHunkIndex() orelse return;
        const target = self.selectedHunkOffset(mode, hunk_index);
        const visible_rows = self.diffVisibleRows();
        if (target < self.viewer.diff_scroll) {
            self.viewer.diff_scroll = target;
        } else if (visible_rows > 0 and target >= self.viewer.diff_scroll + visible_rows) {
            self.viewer.diff_scroll = target + 1 - visible_rows;
        }
    }

    fn clampDiffNavigation(self: *App) void {
        if (self.selectedFile() == null) {
            const line_count = self.selectedProjectionLineCount();
            const visible_rows = self.diffVisibleRows();
            const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
            if (self.viewer.diff_scroll > max_scroll) self.viewer.diff_scroll = max_scroll;
            return;
        }

        if (self.selectedDiffCursorOffset() == null) {
            self.initializeDiffCursorForSelectedFile();
        }

        const mode = self.effectiveDisplayMode();
        const line_count = self.selectedFileLineIndex(mode).lineCount();
        const visible_rows = self.diffVisibleRows();
        const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
        if (self.viewer.diff_scroll > max_scroll) self.viewer.diff_scroll = max_scroll;
    }

    fn selectedProjectionLineCount(self: *const App) usize {
        if (self.selectedStatusEntry() == null) return 0;
        return switch (self.review_projection) {
            .ready => |ready| switch (ready.value) {
                .cached_diff => |bundle| if (bundle.loaded.document.files.len > 0)
                    if (bundle.loaded.cachedRenderedLineIndex(0, self.effectiveDisplayMode())) |index| index.lineCount() else 0
                else
                    0,
                .generated_added_file => |bundle| bundle.file.lines.len + @as(usize, if (bundle.file.truncated) 1 else 0),
                .combined_hunks => |bundle| bundle.projection.lineIndex(self.effectiveDisplayMode()).lineCount(),
                .status_body => 1,
            },
            .pending, .failed => 1,
            .idle => 0,
        };
    }

    fn clampDiffNavigationKeepingHunkVisible(self: *App) void {
        self.clampDiffNavigation();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    fn remapDiffScrollForModeChange(
        self: *const App,
        old_mode: diff_render.DisplayMode,
        new_mode: diff_render.DisplayMode,
        old_scroll: usize,
    ) usize {
        if (old_mode == new_mode) return old_scroll;

        const old_index = self.selectedFileLineIndex(old_mode);
        const new_index = self.selectedFileLineIndex(new_mode);
        if (old_index.lineCount() == 0 or new_index.lineCount() == 0) return 0;

        const hunk_index = old_index.hunkIndexAtOffset(old_scroll) orelse {
            return @min(old_scroll, new_index.lineCount() - 1);
        };

        const old_hunk_offset = old_index.hunkOffset(hunk_index);
        const old_hunk_rows = old_index.hunkLineCount(hunk_index);
        const new_hunk_offset = new_index.hunkOffset(hunk_index);
        const new_hunk_rows = new_index.hunkLineCount(hunk_index);
        if (old_hunk_rows == 0 or new_hunk_rows == 0) return @min(new_hunk_offset, new_index.lineCount() - 1);

        const old_local = @min(old_scroll - old_hunk_offset, old_hunk_rows - 1);
        const new_local = if (old_hunk_rows <= 1)
            0
        else
            old_local * (new_hunk_rows - 1) / (old_hunk_rows - 1);
        return @min(new_hunk_offset + new_local, new_index.lineCount() - 1);
    }

    fn resetDiffPosition(self: *App) void {
        self.viewer.diff_scroll = 0;
        self.initializeDiffCursorForSelectedFile();
        self.clearSearchMatch();
    }

    fn enterSearchMode(self: *App) void {
        if (self.activeCombinedProjection() != null) {
            self.clearSearchMatch();
            self.setStatus("search is unavailable for mixed staged/unstaged view", .{});
            return;
        }
        self.search.input = self.search.query;
        self.search.mode = true;
    }

    fn cancelSearchMode(self: *App) void {
        self.search.input = self.search.query;
        self.search.mode = false;
    }

    fn clearSearch(self: *App) void {
        self.search.mode = false;
        self.search.input = .{};
        self.search.query = .{};
        self.clearSearchMatch();
    }

    fn enterFileSearchMode(self: *App) void {
        self.file_search_return_focus = if (self.viewer.sidebar_hidden) .diff else self.viewer.focus;
        if (!self.viewer.sidebar_hidden) self.viewer.focus = .sidebar;
        self.file_search.mode = true;
        self.file_search.input = .{};
        self.file_search.resetNoMatch();
    }

    fn cancelFileSearchMode(self: *App, allocator: std.mem.Allocator) void {
        self.file_search.deinit(allocator);
        self.viewer.focus = if (self.viewer.sidebar_hidden) .diff else self.file_search_return_focus;
    }

    fn enterRepoPickerMode(self: *App, allocator: std.mem.Allocator) !void {
        if (self.actions.pending != null) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }

        self.repo_picker.mode = true;
        self.repo_picker.prompt_mode = .list;
        self.repo_picker.list.mode = true;
        self.repo_picker.list.input = .{};
        self.repo_picker.list.resetNoMatch();
        self.repo_picker.clearPathStatus();
        self.clearRepoPickerDiscovery(allocator);
        try self.refreshRepoPickerFilter(allocator);
        self.focusRepoPickerOnActive();
    }

    fn cancelRepoPickerMode(self: *App, allocator: std.mem.Allocator) void {
        if (self.repo_picker.mode and self.repo_picker.prompt_mode == .path_input) {
            self.repo_picker.prompt_mode = .list;
            self.repo_picker.invalidatePathDiscovery();
            return;
        }
        self.repo_picker.deinit(allocator);
        self.clearRepoPickerDiscovery(allocator);
        self.clearRepoPickerItems(allocator);
    }

    fn submitRepoPicker(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.repo_picker.prompt_mode == .path_input) {
            try self.submitRepoPickerPath(ctx);
            return;
        }

        const focused = self.repo_picker.list.filter.list.focusedIndex();
        const item_index = self.repo_picker.list.filter.sourceIndex(focused) orelse {
            self.repo_picker.list.no_match = true;
            return;
        };
        if (item_index >= self.repo_picker_items.items.len) {
            self.repo_picker.list.no_match = true;
            return;
        }

        switch (self.repo_picker_items.items[item_index].source) {
            .active_repo => {
                self.repo_picker.deinit(ctx.allocator());
                self.clearRepoPickerItems(ctx.allocator());
            },
            .workspace_repo => |repo_index| {
                const repos = self.repo_state.workspaceRepos() orelse return;
                if (repo_index >= repos.len) {
                    self.repo_picker.list.no_match = true;
                    return;
                }

                self.repo_picker.deinit(ctx.allocator());
                self.clearRepoPickerItems(ctx.allocator());
                self.clearPendingSelectionRestore(ctx.allocator());
                try self.recent_repos.rememberRepo(ctx.allocator(), repos[repo_index].canonical_root);
                if (repo_index == self.repo_state.active_index) return;

                try self.startDiffLoadWithRepoRoot(ctx, repos[repo_index].canonical_root, true);
                self.repo_state.active_index = repo_index;
                self.setSelectedDiffFile(0);
                self.viewer.selected_node = 0;
                self.clearSearch();
            },
            .pending_workspace_repo => |repo_index| {
                try self.acceptPendingRepoPickerWorkspace(ctx, repo_index);
            },
            .recent_repo => |recent_index| {
                if (recent_index >= self.recent_repos.entries.items.len) return;
                try self.startRepoPathDiscovery(ctx, self.recent_repos.entries.items[recent_index].path);
            },
            .recent_workspace => |recent_index| {
                if (recent_index >= self.recent_repos.entries.items.len) return;
                try self.startRepoPathDiscovery(ctx, self.recent_repos.entries.items[recent_index].path);
            },
        }
    }

    fn refreshRepoPickerFilter(self: *App, allocator: std.mem.Allocator) !void {
        self.clearRepoPickerItems(allocator);

        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(allocator);

        if (self.repo_picker_discovery) |discovery| {
            switch (discovery) {
                .workspace => |workspace| {
                    for (workspace.repos, 0..) |repo, index| {
                        try self.appendRepoPickerItem(allocator, repo.display_path, repo.canonical_root, .{ .pending_workspace_repo = index });
                    }
                },
                .single_repo, .none => {},
            }
        } else if (self.repo_state.discovery) |discovery| {
            switch (discovery) {
                .single_repo => |entry| {
                    try self.appendRepoPickerItem(allocator, entry.label, entry.canonical_root, .active_repo);
                },
                .workspace => |workspace| {
                    for (workspace.repos, 0..) |repo, index| {
                        try self.appendRepoPickerItem(allocator, repo.display_path, repo.canonical_root, .{ .workspace_repo = index });
                    }
                },
                .none => {},
            }
        }

        for (self.recent_repos.entries.items, 0..) |entry, index| {
            if (self.repoPickerAlreadyHasPath(entry.path)) continue;
            const label = std.fs.path.basename(entry.path);
            const source: RepoPickerItemSource = switch (entry.kind) {
                .repo => .{ .recent_repo = index },
                .workspace => .{ .recent_workspace = index },
            };
            try self.appendRepoPickerItem(allocator, label, entry.path, source);
        }

        for (self.repo_picker_items.items) |item| {
            try labels.append(allocator, item.label);
        }

        // ListFilter owns the filtered index arrays; repository labels remain
        // borrowed from repo_picker_items, which App owns until the picker is
        // refreshed or closed.
        try self.repo_picker.list.filter.apply(allocator, labels.items, self.repo_picker.list.input.slice());
    }

    fn focusRepoPickerOnActive(self: *App) void {
        var visible_index: usize = 0;
        while (visible_index < self.repo_picker.list.filter.labels.len) : (visible_index += 1) {
            const source_index = self.repo_picker.list.filter.sourceIndex(visible_index) orelse continue;
            if (source_index >= self.repo_picker_items.items.len) continue;
            const source = self.repo_picker_items.items[source_index].source;
            const active = switch (source) {
                .active_repo => true,
                .workspace_repo => |repo_index| repo_index == self.repo_state.active_index,
                .pending_workspace_repo, .recent_repo, .recent_workspace => false,
            };
            if (!active) continue;
            while (self.repo_picker.list.filter.list.focusedIndex() < visible_index) {
                self.repo_picker.list.filter.update(.move_next);
            }
            return;
        }
    }

    fn enterRepoPickerPathInput(self: *App) void {
        if (!self.repo_picker.mode) return;
        self.repo_picker.prompt_mode = .path_input;
        self.repo_picker.clearPathStatus();
    }

    fn insertRepoPickerCodepoint(self: *App, allocator: std.mem.Allocator, codepoint: u21) !void {
        switch (self.repo_picker.prompt_mode) {
            .list => {
                self.repo_picker.list.resetNoMatch();
                self.repo_picker.list.input.insert(codepoint) catch {};
                try self.refreshRepoPickerFilter(allocator);
            },
            .path_input => {
                self.repo_picker.clearPathStatus();
                self.repo_picker.path_input.insert(codepoint) catch {
                    self.repo_picker.path_error = .path_too_long;
                };
            },
        }
    }

    fn insertRepoPickerSlice(self: *App, allocator: std.mem.Allocator, text: []const u8) !void {
        switch (self.repo_picker.prompt_mode) {
            .list => {
                self.repo_picker.list.resetNoMatch();
                self.repo_picker.list.input.insertSlice(text) catch {
                    self.setStatus("repository filter paste is too long", .{});
                    return;
                };
                try self.refreshRepoPickerFilter(allocator);
            },
            .path_input => {
                self.repo_picker.clearPathStatus();
                self.repo_picker.path_input.insertSlice(text) catch {
                    self.repo_picker.path_error = .path_too_long;
                };
            },
        }
    }

    fn backspaceRepoPicker(self: *App, allocator: std.mem.Allocator) !void {
        switch (self.repo_picker.prompt_mode) {
            .list => {
                self.repo_picker.list.resetNoMatch();
                self.repo_picker.list.input.backspace();
                try self.refreshRepoPickerFilter(allocator);
            },
            .path_input => {
                self.repo_picker.clearPathStatus();
                self.repo_picker.path_input.backspace();
            },
        }
    }

    fn moveRepoPickerCursorLeft(self: *App) void {
        switch (self.repo_picker.prompt_mode) {
            .list => self.repo_picker.list.input.moveLeft(),
            .path_input => self.repo_picker.path_input.moveLeft(),
        }
    }

    fn moveRepoPickerCursorRight(self: *App) void {
        switch (self.repo_picker.prompt_mode) {
            .list => self.repo_picker.list.input.moveRight(),
            .path_input => self.repo_picker.path_input.moveRight(),
        }
    }

    fn submitRepoPickerPath(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const path = std.mem.trim(u8, self.repo_picker.path_input.slice(), " \t\r\n");
        if (path.len == 0) {
            self.repo_picker.path_error = .no_git_repositories_found;
            return;
        }
        try self.startRepoPathDiscovery(ctx, path);
    }

    fn startRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), path: []const u8) !void {
        if (self.actions.pending != null) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }

        const task = try ctx.allocator().create(RepoPathDiscoveryTask);
        errdefer ctx.allocator().destroy(task);

        const owned_path = try expandUserPath(ctx.allocator(), path, self.homeDir());
        errdefer ctx.allocator().free(owned_path);

        task.* = .{
            .path = owned_path,
            .generation = self.repo_picker.beginPathDiscovery(),
        };

        ctx.task().spawnWith(task, RepoPathDiscoveryTask.run) catch |err| {
            _ = self.repo_picker.finishPathDiscovery(task.generation);
            self.setStatus("could not start repo path discovery task", .{});
            return err;
        };
    }

    fn homeDir(self: *const App) ?[]const u8 {
        const map = self.env_map orelse return null;
        const home = map.get("HOME") orelse return null;
        if (home.len == 0) return null;
        return home;
    }

    fn finishRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), finished: RepoPathDiscoveryFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.repo_picker.finishPathDiscovery(result.generation)) return;
        if (!self.repo_picker.isCurrentPathDiscovery(result.generation)) return;

        switch (result.result) {
            .empty => unreachable,
            .discovered => |discovery| {
                result.result = .empty;
                try self.acceptRepoPathDiscovery(ctx, discovery);
            },
            .input_error => |err| {
                self.repo_picker.path_error = repoPickerPathError(err);
            },
            .failed => |message| {
                self.setStatus("repo path discovery failed: {s}", .{std.mem.trim(u8, message, " \t\r\n")});
            },
            .failed_static => |message| {
                self.setStatus("repo path discovery failed: {s}", .{message});
            },
        }
    }

    fn acceptRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), discovery: repo_discovery.DiscoveryResult) !void {
        var owned_discovery = discovery;
        errdefer owned_discovery.deinit(ctx.allocator());

        switch (owned_discovery) {
            .single_repo => |entry| {
                try self.recent_repos.rememberRepo(ctx.allocator(), entry.canonical_root);
                self.repo_picker.deinit(ctx.allocator());
                self.clearRepoPickerDiscovery(ctx.allocator());
                self.clearRepoPickerItems(ctx.allocator());
                self.clearPendingSelectionRestore(ctx.allocator());
                self.repo_state.replace(ctx.allocator(), owned_discovery);
                owned_discovery = .{ .none = .{ .current_root = "" } };
                self.repo_state.active_index = 0;
                try self.startDiffLoad(ctx);
                self.setSelectedDiffFile(0);
                self.viewer.selected_node = 0;
                self.clearSearch();
            },
            .workspace => |workspace| {
                try self.recent_repos.rememberWorkspace(ctx.allocator(), workspace.current_root);
                self.clearRepoPickerDiscovery(ctx.allocator());
                self.repo_picker_discovery = owned_discovery;
                owned_discovery = .{ .none = .{ .current_root = "" } };
                self.repo_picker.prompt_mode = .list;
                self.repo_picker.list.mode = true;
                self.repo_picker.list.input = .{};
                self.repo_picker.list.resetNoMatch();
                self.repo_picker.clearPathStatus();
                try self.refreshRepoPickerFilter(ctx.allocator());
            },
            .none => unreachable,
        }
    }

    fn acceptPendingRepoPickerWorkspace(self: *App, ctx: *chasen.Ctx(Msg), repo_index: usize) !void {
        var discovery = self.repo_picker_discovery orelse return;
        self.repo_picker_discovery = null;
        errdefer discovery.deinit(ctx.allocator());

        const workspace = switch (discovery) {
            .workspace => |workspace| workspace,
            .single_repo, .none => return,
        };
        if (repo_index >= workspace.repos.len) {
            discovery.deinit(ctx.allocator());
            self.repo_picker.list.no_match = true;
            return;
        }

        try self.recent_repos.rememberRepo(ctx.allocator(), workspace.repos[repo_index].canonical_root);
        self.repo_picker.deinit(ctx.allocator());
        self.clearRepoPickerItems(ctx.allocator());
        self.clearPendingSelectionRestore(ctx.allocator());
        self.repo_state.replace(ctx.allocator(), discovery);
        discovery = .{ .none = .{ .current_root = "" } };
        self.repo_state.active_index = repo_index;
        try self.startDiffLoad(ctx);
        self.setSelectedDiffFile(0);
        self.viewer.selected_node = 0;
        self.clearSearch();
    }

    fn repoPickerPathError(err: repo_discovery.PathDiscoveryError) app_prompt.RepoPickerPathError {
        return switch (err) {
            error.PathDoesNotExist => .path_does_not_exist,
            error.PathIsNotDirectory => .path_is_not_directory,
            error.CannotAccessPath => .cannot_access_path,
            error.NoGitRepositoriesFound => .no_git_repositories_found,
            else => .cannot_access_path,
        };
    }

    fn appendRepoPickerItem(self: *App, allocator: std.mem.Allocator, label: []const u8, detail: []const u8, source: RepoPickerItemSource) !void {
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const owned_detail = try allocator.dupe(u8, detail);
        errdefer allocator.free(owned_detail);
        try self.repo_picker_items.append(allocator, .{
            .label = owned_label,
            .detail = owned_detail,
            .source = source,
        });
    }

    fn clearRepoPickerItems(self: *App, allocator: std.mem.Allocator) void {
        for (self.repo_picker_items.items) |*item| item.deinit(allocator);
        self.repo_picker_items.clearRetainingCapacity();
    }

    fn deinitRepoPickerItems(self: *App, allocator: std.mem.Allocator) void {
        self.clearRepoPickerItems(allocator);
        self.repo_picker_items.deinit(allocator);
    }

    fn clearRepoPickerDiscovery(self: *App, allocator: std.mem.Allocator) void {
        if (self.repo_picker_discovery) |*discovery| discovery.deinit(allocator);
        self.repo_picker_discovery = null;
    }

    fn repoPickerAlreadyHasPath(self: *const App, path: []const u8) bool {
        if (self.repo_picker_discovery) |discovery| {
            switch (discovery) {
                .workspace => |workspace| {
                    if (std.mem.eql(u8, workspace.current_root, path)) return true;
                    for (workspace.repos) |repo| {
                        if (std.mem.eql(u8, repo.canonical_root, path)) return true;
                    }
                },
                .single_repo => |entry| if (std.mem.eql(u8, entry.canonical_root, path)) return true,
                .none => {},
            }
        }
        if (self.repo_state.discovery) |discovery| {
            switch (discovery) {
                .workspace => |workspace| if (std.mem.eql(u8, workspace.current_root, path)) return true,
                .single_repo, .none => {},
            }
        }
        for (self.repo_picker_items.items) |item| {
            if (std.mem.eql(u8, item.detail, path)) return true;
        }
        return false;
    }

    fn toggleReviewedFile(self: *App, allocator: std.mem.Allocator) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;

        const file_index = self.selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.reviewed_files.len) return;
        const file = loaded.document.files[file_index];
        if (self.activeRepoRoot() != null and diff_file.canonicalPathKey(file) == null) return;

        const reviewed = !loaded.reviewed_files[file_index];
        try self.reviewed_store.set(allocator, self.activeRepoRoot(), file, reviewed);
        loaded.reviewed_files[file_index] = reviewed;
        if (self.review_display.hide_reviewed_files) {
            try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, true, self.review_display.changed_file_filter);
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
            self.clampDiffNavigation();
        }
    }

    fn toggleHideReviewedFiles(self: *App) !void {
        self.review_display.hide_reviewed_files = !self.review_display.hide_reviewed_files;
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        self.clampDiffNavigation();
    }

    fn cycleChangedFileFilter(self: *App) !void {
        self.review_display.changed_file_filter = self.review_display.changed_file_filter.next();
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter);
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        self.clampDiffNavigation();
    }

    fn submitFileSearch(self: *App, allocator: std.mem.Allocator) !void {
        const query = std.mem.trim(u8, self.file_search.input.slice(), " \t\r\n");
        if (query.len == 0) {
            self.cancelFileSearchMode(allocator);
            return;
        }

        const loaded = self.activeLoadedDiff() orelse {
            self.file_search.no_match = true;
            return;
        };
        const node_index = try self.findFileNodeWithFilter(allocator, loaded, query) orelse {
            self.file_search.clearFilter(allocator);
            self.file_search.no_match = true;
            return;
        };

        // Go-to-file should land on the file row, not on a still-collapsed
        // parent directory that hides the matched path.
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        const load_allocator = self.loadArenaAllocator() orelse {
            self.file_search.clearFilter(allocator);
            return;
        };
        loaded.rebuildVisibleNodes(load_allocator, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter) catch {
            self.file_search.clearFilter(allocator);
            self.file_search.no_match = true;
            return;
        };
        self.selectSidebarNode(loaded, node_index);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
        self.cancelFileSearchMode(allocator);
    }

    fn submitSearch(self: *App) void {
        self.search.mode = false;
        if (self.activeCombinedProjection() != null) {
            self.clearSearchMatch();
            self.setStatus("search is unavailable for mixed staged/unstaged view", .{});
            return;
        }
        self.search.query = self.search.input;
        self.clearSearchMatch();
        if (self.search.query.len == 0) {
            return;
        }
        self.selectSearchMatch(.forward);
    }

    fn selectSearchMatch(self: *App, direction: diff_search.Direction) void {
        if (self.activeCombinedProjection() != null) {
            self.clearSearchMatch();
            self.setStatus("search is unavailable for mixed staged/unstaged view", .{});
            return;
        }
        const file = self.selectedFile() orelse return;
        if (self.search.query.len == 0) return;

        const line_count = self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const base = if (self.search.match) |match| match.coordinate else null;
        const next = diff_search.findMatch(file, self.effectiveDisplayMode(), self.search.query.slice(), base, direction) orelse {
            self.clearSearchMatch();
            return;
        };
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        self.viewer.diff_cursor = next.coordinate;
        self.resetDiffHorizontalScroll();
        self.applyDiffCursorScrolloff();
        self.clampDiffNavigation();
    }

    fn refreshSearchForSelectedFile(self: *App) void {
        self.clearSearchMatch();
        if (self.search.query.len == 0) return;
        if (self.activeCombinedProjection() != null) return;
        const file = self.selectedFile() orelse return;
        const next = diff_search.findMatch(file, self.effectiveDisplayMode(), self.search.query.slice(), null, .forward) orelse return;
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        self.viewer.diff_cursor = next.coordinate;
        self.applyDiffCursorScrolloff();
    }

    fn clearSearchMatch(self: *App) void {
        self.search.match = null;
        self.search.match_offset = null;
    }

    fn setSearchMatch(self: *App, match: diff_search.Match) void {
        self.search.match = match;
        self.updateSearchMatchOffset();
    }

    fn updateSearchMatchOffset(self: *App) void {
        self.search.match_offset = null;
        const match = self.search.match orelse return;
        if (self.activeCombinedProjection() != null) {
            self.clearSearchMatch();
            return;
        }
        const file = self.selectedFile() orelse return;
        const mode = self.effectiveDisplayMode();
        const offset = diff_view_model.renderedOffsetForCoordinate(file, mode, match.coordinate, self.selectedFileCachedLineIndex(mode)) orelse {
            self.clearSearchMatch();
            return;
        };
        self.search.match_offset = offset;
    }

    fn unfoldSearchMatchIfNeeded(self: *App, match: diff_search.Match) void {
        const hunk_index = switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index,
            else => return,
        };
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.selectedFileIndex(loaded) orelse return;
        if (!loaded.isHunkFolded(file_index, hunk_index)) return;
        loaded.setHunkFolded(file_index, hunk_index, false);
    }

    fn currentSearchMatchInHunkBody(self: *const App, hunk_index: usize) bool {
        const match = self.search.match orelse return false;
        return switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index == hunk_index,
            else => false,
        };
    }

    fn scrollSearchMatchIntoView(self: *App) void {
        const offset = self.search.match_offset orelse return;
        const visible_rows = self.diffVisibleRows();
        if (offset < self.viewer.diff_scroll) {
            self.viewer.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.viewer.diff_scroll + visible_rows) {
            self.viewer.diff_scroll = offset + 1 - visible_rows;
        }
    }

    fn finishReview(self: *App, ctx: *chasen.Ctx(Msg), decision: review_session.Decision) !void {
        const output = self.review_output orelse {
            self.setStatus("review output is not configured", .{});
            return;
        };

        var reviewed_paths: std.ArrayList([]const u8) = .empty;
        defer reviewed_paths.deinit(ctx.allocator());
        self.reviewed_store.appendPathKeysForRepo(ctx.allocator(), self.activeRepoRoot(), &reviewed_paths) catch {
            self.setStatus("could not finalize review result", .{});
            return;
        };
        std.mem.sort([]const u8, reviewed_paths.items, {}, pathLessThan);

        // Quit only after serialization succeeds; otherwise the TUI remains
        // open and stdout never receives a partial machine-readable result.
        output.set(ctx.allocator(), decision, self.selectionContext(), reviewed_paths.items) catch {
            self.setStatus("could not finalize review result", .{});
            return;
        };
        ctx.quit();
    }

    pub fn selectionContext(self: *const App) context.SelectionContext {
        const loaded = self.activeLoadedDiffConst();
        return .{
            .repo_root = self.activeRepoRoot(),
            .source = sourceContext(self.config.source),
            // Status-only rows currently live behind the loaded-diff gate.
            // When GitStatusState can exist without a diff document, widen this
            // branch to validate status-only targets against that model.
            .selected = if (loaded) |active_loaded| self.selectionForLoaded(active_loaded) else null,
        };
    }

    fn sourceContext(source: SourceMode) context.SourceContext {
        // Labels intentionally mirror CliConfig.sourceLabel(); this helper is
        // the boundary where CLI source modes become neutral context data.
        return switch (source) {
            .unstaged => .{ .kind = .unstaged, .label = "unstaged changes" },
            .cached => .{ .kind = .cached, .label = "staged changes" },
            .stdin => .{ .kind = .stdin, .label = "stdin diff" },
            .pager => .{ .kind = .pager, .label = "pager diff" },
            .patch_file => |path| .{ .kind = .patch_file, .label = "patch file", .detail = path },
            .range => |range| .{ .kind = .range, .label = "range", .detail = range },
            .no_index => |paths| .{
                .kind = .no_index,
                .label = "difftool",
                .left_path = paths.left,
                .right_path = paths.right,
            },
        };
    }

    fn selectionForLoaded(self: *const App, loaded: *const LoadedDiff) ?context.Selection {
        const target = self.viewer.selected_target orelse return null;
        return switch (target) {
            .diff_file => |file_index| self.diffFileSelection(loaded, file_index),
            .status_only => |status_index| self.statusOnlySelection(status_index),
        };
    }

    fn selectedStagePathKey(self: *const App) ?[]const u8 {
        const selection = self.selectionContext().selected orelse return null;
        return switch (selection) {
            .diff_file => |file| file.path_key,
            .status_only => |status| status.path_key,
        };
    }

    fn selectedSidebarActionTarget(self: *const App) ?GitActionPath {
        const loaded = self.activeLoadedDiffConst() orelse {
            const path = self.selectedStagePathKey() orelse return null;
            return .{ .path = path, .kind = .file };
        };
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return null;

        // Directory rows intentionally do not update selected_target; actions
        // must use the sidebar cursor so they do not hit the previous file.
        const node = loaded.tree.nodes[self.viewer.selected_node];
        return switch (node.target) {
            .directory => |path| .{ .path = if (path.len > 0) path else node.path, .kind = .directory },
            .diff_file, .status_entry => .{
                .path = if (node.path_key.len > 0) node.path_key else node.path,
                .kind = .file,
            },
        };
    }

    fn statusEntryForPathKey(self: *const App, path_key: []const u8) ?git_status.StatusEntry {
        for (self.git_status.document.entries) |entry| {
            const entry_key = entry.canonicalPathKey() orelse continue;
            if (std.mem.eql(u8, entry_key, path_key)) return entry;
        }
        return null;
    }

    fn selectedDirectoryStageTarget(self: *const App, repo_root: []const u8, directory: []const u8) StageTargetResult {
        if (self.status_load_pending != null) return .stale_status;
        const snapshot_root = self.git_status.repo_root orelse return .stale_status;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return .stale_status;

        var has_stageable = false;
        for (self.git_status.document.entries) |entry| {
            const key = entry.canonicalPathKey() orelse continue;
            if (!file_tree.isPathDescendantOfDirectory(key, directory)) continue;

            // Git operates on the whole directory path. Reject conflicts here
            // so first-slice directory actions cannot resolve them implicitly.
            if (entry.isConflict()) return .{ .conflict_unsupported = directory };

            switch (file_tree.stagePresenceFromEntry(entry)) {
                .untracked, .unstaged_only, .mixed => has_stageable = true,
                .staged_only, .clean_or_unknown, .conflict => {},
            }
        }

        if (!has_stageable) return .{ .no_stageable_content = directory };
        return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory } };
    }

    fn selectedDirectoryUnstageTarget(self: *const App, repo_root: []const u8, directory: []const u8) UnstageTargetResult {
        if (self.status_load_pending != null) return .stale_status;
        const snapshot_root = self.git_status.repo_root orelse return .stale_status;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return .stale_status;

        var has_staged = false;
        for (self.git_status.document.entries) |entry| {
            const key = entry.canonicalPathKey() orelse continue;
            if (!file_tree.isPathDescendantOfDirectory(key, directory)) continue;

            if (entry.isConflict()) return .{ .conflict_unsupported = .{ .path = directory, .kind = .directory } };

            switch (file_tree.stagePresenceFromEntry(entry)) {
                .staged_only, .mixed => has_staged = true,
                .untracked, .unstaged_only, .clean_or_unknown, .conflict => {},
            }
        }

        if (!has_staged) return .{ .no_staged_content = .{ .path = directory, .kind = .directory } };
        return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory } };
    }

    fn freshStatusEntryForPathKey(self: *const App, repo_root: []const u8, path_key: []const u8) ?git_status.StatusEntry {
        if (self.status_load_pending != null) return null;
        const snapshot_root = self.git_status.repo_root orelse return null;
        if (!std.mem.eql(u8, snapshot_root, repo_root)) return null;
        return self.statusEntryForPathKey(path_key);
    }

    fn isFreshStagedOnlyPath(self: *const App, repo_root: []const u8, path_key: []const u8) bool {
        const entry = self.freshStatusEntryForPathKey(repo_root, path_key) orelse return false;
        return !entry.isConflict() and entry.isStaged() and !entry.isUnstaged();
    }

    fn setPendingSelectionRestore(self: *App, allocator: std.mem.Allocator, path_key: []const u8) !void {
        self.clearPendingSelectionRestore(allocator);
        const visible_row = if (self.activeLoadedDiffConst()) |loaded|
            loaded.visibleRowOfNode(self.viewer.selected_node) orelse 0
        else
            0;
        self.pending_selection_restore = .{
            .path_key = try allocator.dupe(u8, path_key),
            .visible_row = visible_row,
        };
    }

    fn clearPendingSelectionRestore(self: *App, allocator: std.mem.Allocator) void {
        if (self.pending_selection_restore) |*restore| restore.deinit(allocator);
        self.pending_selection_restore = null;
    }

    fn restorePendingSelectionOrFallback(self: *App, allocator: std.mem.Allocator, loaded: *LoadedDiff) bool {
        const restore = self.pending_selection_restore orelse return false;
        defer self.clearPendingSelectionRestore(allocator);

        if (findNodeByPathKey(loaded, restore.path_key)) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return true;
        }

        if (loaded.visibleNodeCount() == 0) {
            self.viewer.selected_target = null;
            self.viewer.selected_node = 0;
            return true;
        }

        const row = @min(restore.visible_row, loaded.visibleNodeCount() - 1);
        if (nearestVisibleFileNode(loaded, row)) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return true;
        }

        return false;
    }

    fn restorePendingSelectionByPath(self: *App, allocator: std.mem.Allocator, loaded: *LoadedDiff) bool {
        const restore = self.pending_selection_restore orelse return false;
        if (findNodeByPathKey(loaded, restore.path_key)) |node_index| {
            defer self.clearPendingSelectionRestore(allocator);
            self.selectSidebarNode(loaded, node_index);
            return true;
        }
        return false;
    }

    fn findNodeByPathKey(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
        for (loaded.tree.nodes, 0..) |node, index| {
            const node_key = if (node.path_key.len > 0) node.path_key else node.path;
            if (std.mem.eql(u8, node_key, path_key)) return index;
        }
        return null;
    }

    fn findFileNodeByPathKey(loaded: *const LoadedDiff, path_key: []const u8) ?usize {
        for (loaded.tree.nodes, 0..) |node, index| {
            if (node.kind != .file) continue;
            const node_key = if (node.path_key.len > 0) node.path_key else node.path;
            if (std.mem.eql(u8, node_key, path_key)) return index;
        }
        return null;
    }

    fn nearestVisibleFileNode(loaded: *const LoadedDiff, visible_row: usize) ?usize {
        var row = visible_row;
        while (row < loaded.visibleNodeCount()) : (row += 1) {
            const node_index = loaded.visibleNodeAt(row) orelse continue;
            if (loaded.tree.nodes[node_index].kind == .file) return node_index;
        }

        row = @min(visible_row, loaded.visibleNodeCount() - 1);
        while (true) {
            const node_index = loaded.visibleNodeAt(row) orelse return null;
            if (loaded.tree.nodes[node_index].kind == .file) return node_index;
            if (row == 0) break;
            row -= 1;
        }
        return null;
    }

    fn diffFileSelection(self: *const App, loaded: *const LoadedDiff, file_index: usize) ?context.Selection {
        if (file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        return .{ .diff_file = .{
            .file_index = file_index,
            .display_path = diff_file.displayPath(file),
            .path_key = diff_file.canonicalPathKey(file),
            .hunk_index = if (self.selectedHunkIndex()) |hunk_index|
                if (hunk_index < file.hunks.len) hunk_index else null
            else
                null,
        } };
    }

    fn statusOnlySelection(self: *const App, status_index: usize) ?context.Selection {
        if (status_index >= self.git_status.document.entries.len) {
            return .{ .status_only = .{ .status_index = status_index } };
        }
        const entry = self.git_status.document.entries[status_index];
        return .{ .status_only = .{
            .status_index = status_index,
            .path_key = entry.canonicalPathKey(),
        } };
    }

    pub fn selectedStatusEntry(self: *const App) ?git_status.StatusEntry {
        const target = self.viewer.selected_target orelse return null;
        const status_index = switch (target) {
            .status_only => |index| index,
            else => return null,
        };
        if (status_index >= self.git_status.document.entries.len) return null;
        return self.git_status.document.entries[status_index];
    }

    fn ensureTreeOrderScope(self: *App, allocator: std.mem.Allocator) !void {
        const scope = try self.treeOrderScopeText(allocator);
        defer allocator.free(scope);

        if (self.tree_order_scope) |current| {
            if (std.mem.eql(u8, current, scope)) return;
            allocator.free(current);
            self.tree_order_scope = null;
            self.tree_order.reset(allocator);
        }

        self.tree_order_scope = try allocator.dupe(u8, scope);
    }

    fn treeOrderScopeText(self: *const App, allocator: std.mem.Allocator) ![]u8 {
        const repo_root = self.activeRepoRoot() orelse "";
        return switch (self.config.source) {
            .unstaged => std.fmt.allocPrint(allocator, "{s}\x1funstaged", .{repo_root}),
            .cached => std.fmt.allocPrint(allocator, "{s}\x1fcached", .{repo_root}),
            .range => |range| std.fmt.allocPrint(allocator, "{s}\x1frange\x1f{s}", .{ repo_root, range }),
            .patch_file => |path| std.fmt.allocPrint(allocator, "{s}\x1fpatch\x1f{s}", .{ repo_root, path }),
            .stdin => std.fmt.allocPrint(allocator, "{s}\x1fstdin", .{repo_root}),
            .pager => std.fmt.allocPrint(allocator, "{s}\x1fpager", .{repo_root}),
            .no_index => |paths| std.fmt.allocPrint(allocator, "{s}\x1fno-index\x1f{s}\x1f{s}", .{ repo_root, paths.left, paths.right }),
        };
    }

    fn stableOrderOptions(self: *App, allocator: std.mem.Allocator) ?file_tree.StableOrderOptions {
        return .{
            .allocator = allocator,
            .order = &self.tree_order,
        };
    }

    fn selectedFile(self: *const App) ?diff_parser.FileDiff {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.document.files[file_index];
    }

    pub fn activeDiffDisplay(self: *const App, allocator: std.mem.Allocator, mode: diff_render.DisplayMode) !?ActiveDiffDisplay {
        if (self.activeCombinedProjection()) |bundle| {
            const states = bundle.projection.hunk_states;
            const flags = try allocator.alloc(bool, states.len);
            for (states, flags) |state, *flag| flag.* = state.state == .staged;
            return .{ .combined_projection = .{
                .file = bundle.projection.file,
                .line_index = bundle.projection.lineIndex(mode),
                .staged_flags = flags,
                .hunk_states = states,
            } };
        }

        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        const file = loaded.document.files[file_index];
        return .{ .loaded = .{
            .file = file,
            .line_index = loaded.cachedRenderedLineIndex(file_index, mode),
            .folded_hunks = loaded.foldedHunksForFile(file_index),
            .staged_flags = try self.stagedHunkFlagsForFile(allocator, file),
        } };
    }

    fn activeCombinedProjection(self: *const App) ?*const app_review_projection.CombinedHunkBundle {
        // Recompute the target identity on each call so reload/status
        // generation changes cannot leave a stale projection active.
        const target = self.reviewProjectionTarget() orelse return null;
        if (target.kind != .combined_hunks) return null;

        return switch (self.review_projection) {
            .ready => |*ready| blk: {
                if (!ready.request.matchesBorrowed(
                    target.repo_root,
                    target.path_key,
                    target.kind,
                    target.source_kind,
                    self.load.generation,
                    self.status_load_generation,
                )) break :blk null;
                break :blk switch (ready.value) {
                    .combined_hunks => |*bundle| bundle,
                    else => null,
                };
            },
            else => null,
        };
    }

    fn selectedFileLineIndex(self: *const App, mode: diff_render.DisplayMode) diff_view_model.RenderedLineIndex {
        if (self.activeCombinedProjection()) |bundle| return bundle.projection.lineIndex(mode);
        const loaded = self.activeLoadedDiffConst() orelse return .{ .mode = mode };
        const file_index = self.selectedFileIndex(loaded) orelse return .{ .mode = mode };
        return loaded.renderedLineIndex(file_index, mode);
    }

    fn selectedFileCachedLineIndex(self: *const App, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.cachedRenderedLineIndex(file_index, mode);
    }

    fn selectedFoldedHunks(self: *const App) []const bool {
        if (self.activeCombinedProjection() != null) return &.{};
        const loaded = self.activeLoadedDiffConst() orelse return &.{};
        const file_index = self.selectedFileIndex(loaded) orelse return &.{};
        return loaded.foldedHunksForFile(file_index);
    }

    fn selectedHunkOffset(self: *const App, mode: diff_render.DisplayMode, hunk_index: usize) usize {
        if (self.activeCombinedProjection()) |bundle| return bundle.projection.lineIndex(mode).hunkOffset(hunk_index);
        const loaded = self.activeLoadedDiffConst() orelse return 0;
        const file_index = self.selectedFileIndex(loaded) orelse return 0;
        if (loaded.rendered_line_cache.indexFor(file_index, mode)) |index| return index.hunkOffset(hunk_index);
        return diff_view_model.hunkBodyLineOffsetFolded(loaded.document.files[file_index], mode, hunk_index, loaded.foldedHunksForFile(file_index));
    }

    pub fn selectedHunkIndex(self: *const App) ?usize {
        return switch (self.viewer.diff_cursor) {
            .hunk_header => |hunk_index| hunk_index,
            .hunk_line => |line| line.hunk_index,
            .metadata, .binary_marker => null,
        };
    }

    pub fn stagedHunkFlagsForFile(self: *const App, allocator: std.mem.Allocator, file: diff_parser.FileDiff) ![]const bool {
        if (self.staged_hunks.items.items.len == 0 or file.hunks.len == 0) return &.{};
        const repo_root = self.activeRepoRoot() orelse return &.{};
        const path = diff_file.canonicalPathKey(file) orelse return &.{};

        var marked_count: usize = 0;
        for (0..file.hunks.len) |hunk_index| {
            if (self.staged_hunks.contains(repo_root, path, hunk_index)) marked_count += 1;
        }

        if (marked_count == 0) return &.{};
        if (marked_count == file.hunks.len and self.isFreshStagedOnlyPath(repo_root, path)) return &.{};

        const flags = try allocator.alloc(bool, file.hunks.len);
        @memset(flags, false);
        for (flags, 0..) |*flag, hunk_index| {
            flag.* = self.staged_hunks.contains(repo_root, path, hunk_index);
        }
        return flags;
    }

    fn selectedDiffCursorOffset(self: *const App) ?usize {
        const mode = self.effectiveDisplayMode();
        const file = if (self.activeCombinedProjection()) |bundle| bundle.projection.file else self.selectedFile() orelse return null;
        const index = if (self.activeCombinedProjection()) |bundle| bundle.projection.lineIndex(mode) else self.selectedFileCachedLineIndex(mode);
        return diff_view_model.renderedOffsetForCoordinate(file, mode, self.viewer.diff_cursor, index);
    }

    fn selectedCoordinateAtOffset(self: *const App, offset: usize) ?diff_view_model.BodyCoordinate {
        const mode = self.effectiveDisplayMode();
        const file = if (self.activeCombinedProjection()) |bundle| bundle.projection.file else self.selectedFile() orelse return null;
        const index = if (self.activeCombinedProjection()) |bundle| bundle.projection.lineIndex(mode) else self.selectedFileCachedLineIndex(mode);
        return diff_view_model.coordinateAtOffset(file, mode, offset, self.selectedFoldedHunks(), index);
    }

    fn initializeDiffCursorForSelectedFile(self: *App) void {
        self.viewer.diff_cursor = self.selectedCoordinateAtOffset(0) orelse .{ .metadata = 0 };
    }

    pub fn visibleDiffCursorOffset(self: *const App) ?usize {
        const offset = self.selectedDiffCursorOffset() orelse return null;
        const visible_rows = self.diffVisibleRows();
        if (offset < self.viewer.diff_scroll) return null;
        if (visible_rows == 0 or offset >= self.viewer.diff_scroll + visible_rows) return null;
        return offset;
    }

    fn diffCursorIsVisible(self: *const App) bool {
        return self.visibleDiffCursorOffset() != null;
    }

    fn applyDiffCursorScrolloff(self: *App) void {
        const cursor_offset = self.selectedDiffCursorOffset() orelse {
            self.clampDiffNavigation();
            return;
        };
        const visible_rows = self.diffVisibleRows();
        if (visible_rows == 0) {
            self.clampDiffNavigation();
            return;
        }
        const margin = @min(@as(usize, 8), visible_rows / 3);
        if (cursor_offset < self.viewer.diff_scroll + margin) {
            self.viewer.diff_scroll = cursor_offset -| margin;
        } else {
            const lower_edge = self.viewer.diff_scroll + visible_rows -| margin;
            if (cursor_offset >= lower_edge) {
                self.viewer.diff_scroll = cursor_offset + margin + 1 - visible_rows;
            }
        }
        self.clampDiffNavigation();
    }

    fn syncDiffCursorAfterViewportScroll(self: *App, delta: i2, old_scroll: usize, old_cursor_offset: ?usize) void {
        const line_count = self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const visible_rows = self.diffVisibleRows();
        if (visible_rows == 0) return;

        // Mouse-wheel scrolling is viewport-first, but hunk actions still use
        // the diff cursor. Keep the cursor near the user's visible scroll
        // position without letting normal scrolloff pull the viewport back.
        const margin = @min(@as(usize, 8), visible_rows / 3);
        const target = if (old_cursor_offset) |offset| blk: {
            if (offset >= old_scroll and offset < old_scroll + visible_rows) {
                break :blk self.viewer.diff_scroll + (offset - old_scroll);
            }
            if (delta < 0) break :blk self.viewer.diff_scroll + margin;
            break :blk self.viewer.diff_scroll + visible_rows - 1 -| margin;
        } else blk: {
            if (delta < 0) break :blk self.viewer.diff_scroll + margin;
            break :blk self.viewer.diff_scroll + visible_rows - 1 -| margin;
        };

        self.viewer.diff_cursor = self.selectedCoordinateAtOffset(@min(target, line_count - 1)) orelse self.viewer.diff_cursor;
    }

    fn loadedFileCount(self: *const App) ?usize {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        return loaded.document.files.len;
    }

    fn effectiveDisplayMode(self: *const App) diff_render.DisplayMode {
        return diff_render.effectiveMode(self.diffPaneWidth(), self.viewer.display_mode);
    }

    fn layoutSize(self: *const App) chasen.Size {
        return app_view.shellContentSize(self.terminal_size);
    }

    fn diffVisibleRows(self: *const App) usize {
        return diff_render.visibleBodyRows(terminalBodyHeight(self.layoutSize().height));
    }

    fn diffPaneWidth(self: *const App) u16 {
        const width = self.layoutSize().width;
        if (self.viewer.sidebar_hidden) return contentWidth(width);
        const sidebar_width = sidebarWidth(width, self.viewer.sidebar_width);
        if (width <= sidebar_width + 1) return 0;
        return contentWidth(width - sidebar_width - 1);
    }

    fn toggleSidebarVisibility(self: *App) void {
        const previous_width = self.diffPaneWidth();
        self.viewer.sidebar_hidden = !self.viewer.sidebar_hidden;
        if (self.viewer.sidebar_hidden) self.viewer.focus = .diff;
        self.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    fn adjustSidebarWidth(self: *App, direction: i2) void {
        const total_width = self.layoutSize().width;
        const previous_width = self.diffPaneWidth();
        const current = sidebarWidth(total_width, self.viewer.sidebar_width);
        const step: u16 = 4;
        const next = if (direction < 0)
            if (current > step) current - step else 0
        else
            current +| step;

        self.viewer.sidebar_width = sidebarWidth(total_width, next);
        self.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
        self.clampDiffNavigationKeepingHunkVisible();
        self.updateSearchMatchOffset();
        self.scrollSearchMatchIntoView();
        self.clampDiffNavigation();
    }

    fn resetDiffHorizontalScroll(self: *App) void {
        self.viewer.diff_horizontal_scroll = 0;
    }

    fn resetDiffHorizontalScrollIfPaneWidthChanged(self: *App, previous_width: u16) void {
        if (self.diffPaneWidth() != previous_width) self.resetDiffHorizontalScroll();
    }

    fn clampSelection(self: *App, file_count: usize) void {
        if (file_count == 0) {
            if (self.activeLoadedDiff()) |loaded| {
                if (loaded.tree.nodes.len > 0) {
                    self.viewer.selected_node = @min(self.viewer.selected_node, loaded.tree.nodes.len - 1);
                    const node = loaded.tree.nodes[self.viewer.selected_node];
                    self.viewer.selected_target = switch (node.target) {
                        .status_entry => |status_index| .{ .status_only = status_index },
                        .diff_file => |file_index| .{ .diff_file = file_index },
                        .directory => self.viewer.selected_target,
                    };
                    return;
                }
            }
            self.viewer.selected_target = null;
            self.viewer.selected_file = 0;
            self.viewer.selected_node = 0;
            return;
        }
        if (self.viewer.selected_target) |target| {
            switch (target) {
                .diff_file => |file_index| if (file_index >= file_count) {
                    self.setSelectedDiffFile(file_count - 1);
                },
                .status_only => |status_index| if (status_index >= self.git_status.document.entries.len) {
                    self.setSelectedDiffFile(file_count - 1);
                },
            }
        } else {
            self.setSelectedDiffFile(file_count - 1);
        }
        if (self.activeLoadedDiff()) |loaded| {
            if (self.viewer.selected_node >= loaded.tree.nodes.len) {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            if (loaded.visibleAncestorOrSelf(self.viewer.selected_node)) |visible_node| {
                self.viewer.selected_node = visible_node;
            } else if (self.selectedFileIndex(loaded)) |file_index| {
                if (loaded.tree.selectedNodeIndex(file_index)) |file_node| {
                    self.viewer.selected_node = file_node;
                }
            }
        }
    }

    fn reconcileSelectionAfterVisibleNodeChange(self: *App, loaded: *LoadedDiff) void {
        if (loaded.visibleRowOfNode(self.viewer.selected_node) != null) {
            return;
        }

        if (loaded.firstVisibleFileNode()) |file_node| {
            self.selectSidebarNode(loaded, file_node);
            return;
        }

        if (loaded.visibleAncestorOrSelf(self.viewer.selected_node)) |visible_node| {
            self.selectSidebarNode(loaded, visible_node);
            return;
        }

        if (loaded.visibleNodeAt(0)) |node_index| {
            self.viewer.selected_node = node_index;
        }
    }

    pub fn selectedFileIndex(self: *const App, loaded: *const LoadedDiff) ?usize {
        if (loaded.document.files.len == 0) return null;
        const file_index = self.selectedDiffFileTarget() orelse return null;
        return @min(file_index, loaded.document.files.len - 1);
    }

    fn selectedDiffFileTarget(self: *const App) ?usize {
        const target = self.viewer.selected_target orelse return null;
        return target.diffFileIndex();
    }

    fn setSelectedDiffFile(self: *App, file_index: usize) void {
        self.viewer.selected_target = .{ .diff_file = file_index };
        self.viewer.selected_file = file_index;
    }

    fn syncSidebarNodeToSelectedFile(self: *App, loaded: *const LoadedDiff) void {
        const file_index = self.selectedFileIndex(loaded) orelse {
            self.viewer.selected_node = 0;
            return;
        };
        self.viewer.selected_node = loaded.tree.selectedNodeIndex(file_index) orelse 0;
    }

    fn selectFirstVisibleFile(self: *App, loaded: *LoadedDiff) void {
        if (loaded.firstVisibleFileNode()) |node_index| {
            self.selectSidebarNode(loaded, node_index);
            return;
        }
        // Empty or fully filtered trees keep the existing fallback selection.
        self.syncSidebarNodeToSelectedFile(loaded);
    }

    fn materializeReviewedFiles(self: *App, allocator: std.mem.Allocator, loaded: *LoadedDiff) !void {
        const reviewed_files = try allocator.alloc(bool, loaded.document.files.len);
        errdefer allocator.free(reviewed_files);

        for (loaded.document.files, 0..) |file, index| {
            reviewed_files[index] = try self.reviewed_store.containsFile(allocator, self.activeRepoRoot(), file);
        }
        loaded.reviewed_files = reviewed_files;
    }

    fn findFileNodeWithFilter(self: *App, allocator: std.mem.Allocator, loaded: *const LoadedDiff, query: []const u8) !?usize {
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(allocator);
        var node_indexes: std.ArrayList(usize) = .empty;
        defer node_indexes.deinit(allocator);

        for (loaded.tree.nodes, 0..) |node, index| {
            if (node.kind != .file) continue;
            if (!loaded.shouldIncludeFileNode(index, self.review_display.hide_reviewed_files, self.review_display.changed_file_filter)) continue;
            try labels.append(allocator, node.path);
            try node_indexes.append(allocator, index);
        }

        // ListFilter owns the filtered index arrays, while file path labels
        // remain borrowed from the active LoadedDiff.
        try self.file_search.filter.applyWithSourceIndexes(allocator, labels.items, node_indexes.items, query);
        return self.file_search.filter.sourceIndex(0);
    }

    fn loadedDiff(self: *App) ?*LoadedDiff {
        return self.activeLoadedDiff();
    }

    fn activeLoadedDiff(self: *App) ?*LoadedDiff {
        return switch (self.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }

    fn activeLoadedDiffConst(self: *const App) ?*const LoadedDiff {
        return switch (self.load.state) {
            .loaded => |*session| &session.loaded,
            else => null,
        };
    }

    fn loadArenaAllocator(self: *App) ?std.mem.Allocator {
        return switch (self.load.state) {
            .loaded => |*session| session.arena.allocator(),
            .failed => |*failed| failed.arena.allocator(),
            else => null,
        };
    }
};

const footer_rows: u16 = app_view.footer_rows;
const sidebar_header_rows: u16 = app_view.sidebar_header_rows;
const diff_body_start_row: u16 = app_view.diff_body_start_row;

fn contentWidth(width: u16) u16 {
    return app_view.contentWidth(width);
}

fn terminalBodyHeight(terminal_height: u16) u16 {
    return app_view.terminalBodyHeight(terminal_height);
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return app_view.sidebarWidth(total_width, preferred_width);
}

fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, pane_width: u16, line_numbers: bool) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, visibleTextWidth(pane_width, diff_render.lineTextStart(line_numbers, .unified))),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, pane_width, line_numbers),
        else => 0,
    };
}

fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, pane_width: u16, line_numbers: bool) usize {
    const gutter_col = pane_width / 2;
    const new_col = gutter_col + 1;
    const text_col = diff_render.lineTextStart(line_numbers, .side_by_side);
    const old_text_width: u16 = visibleTextWidth(gutter_col, text_col);
    const new_width: u16 = if (pane_width > new_col) pane_width - new_col else 0;
    const new_text_width: u16 = visibleTextWidth(new_width, text_col);
    var max_scroll: usize = 0;
    switch (side_row) {
        .single => |line| {
            switch (line.kind) {
                .added => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width)),
                .context => {
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
                    max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
                },
                else => max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width)),
            }
        },
        .paired => |pair| {
            if (pair.removed) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, old_text_width));
            if (pair.added) |line| max_scroll = @max(max_scroll, maxHorizontalScrollForText(line.text, new_text_width));
        },
    }
    return max_scroll;
}

fn visibleTextWidth(total_width: u16, text_col: u16) u16 {
    return if (total_width > text_col) total_width - text_col else 0;
}

fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const width = chasen.text.displayWidth(text);
    if (width <= visible_width) return 0;
    return width - visible_width;
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "countLines handles empty and trailing newline inputs" {
    try std.testing.expectEqual(@as(usize, 0), app_load.countLines(""));
    try std.testing.expectEqual(@as(usize, 1), app_load.countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), app_load.countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), app_load.countLines("one\ntwo"));
}

test "file selection boundary does not reset diff position" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .diff_scroll = 4,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    };

    app.selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 4), app.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), app.selectedHunkIndex());

    app.selectFileAbsolute(0);
    try std.testing.expectEqual(@as(usize, 4), app.viewer.diff_scroll);
    try std.testing.expectEqual(@as(?usize, 1), app.selectedHunkIndex());
}

test "mode toggle keeps selected hunk visible" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_header = 1 },
        },
    };

    app.scrollSelectedHunkIntoView();
    try std.testing.expect(app.viewer.diff_scroll > 0);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();

    const file = testFileWithHunks();
    const target = diff_render.hunkBodyLineOffset(file, app.effectiveDisplayMode(), app.selectedHunkIndex().?);
    const visible_rows = app.diffVisibleRows();
    try std.testing.expect(target >= app.viewer.diff_scroll);
    try std.testing.expect(visible_rows == 0 or target < app.viewer.diff_scroll + visible_rows);
}

test "sidebar visibility toggle uses full diff width and keeps selection" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .focus = .sidebar,
            .selected_file = 0,
            .selected_node = 1,
            .display_mode = .side_by_side,
        },
    };

    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.effectiveDisplayMode());

    app.toggleSidebarVisibility();

    try std.testing.expect(app.viewer.sidebar_hidden);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.effectiveDisplayMode());

    app.toggleSidebarVisibility();

    try std.testing.expect(!app.viewer.sidebar_hidden);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.effectiveDisplayMode());
}

test "sidebar width adjustment clamps and affects effective mode" {
    var app: App = .{
        .terminal_size = .{ .width = 102, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .display_mode = .side_by_side },
    };

    try std.testing.expectEqual(@as(?u16, null), app.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.effectiveDisplayMode());

    app.adjustSidebarWidth(-1);
    try std.testing.expectEqual(@as(?u16, 30), app.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.unified, app.effectiveDisplayMode());

    app.adjustSidebarWidth(-1);
    try std.testing.expectEqual(@as(?u16, 26), app.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.effectiveDisplayMode());

    app.adjustSidebarWidth(1);
    try std.testing.expectEqual(@as(?u16, 30), app.viewer.sidebar_width);
}

test "sidebar width remains stored while sidebar is hidden" {
    var app: App = .{
        .terminal_size = .{ .width = 102, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .display_mode = .side_by_side },
    };

    app.adjustSidebarWidth(-1);
    app.toggleSidebarVisibility();
    app.adjustSidebarWidth(-1);

    try std.testing.expect(app.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.effectiveDisplayMode());

    app.toggleSidebarVisibility();

    try std.testing.expect(!app.viewer.sidebar_hidden);
    try std.testing.expectEqual(@as(?u16, 26), app.viewer.sidebar_width);
    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.effectiveDisplayMode());
}

test "horizontal scroll uses diff focus arrows and clamps to visible text" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 12 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{ .focus = .diff, .display_mode = .unified },
    };

    app.scrollDiffHorizontal(1);
    try std.testing.expectEqual(@as(usize, 8), app.viewer.diff_horizontal_scroll);

    for (0..20) |_| app.scrollDiffHorizontal(1);
    try std.testing.expect(app.viewer.diff_horizontal_scroll > 0);
    try std.testing.expect(app.viewer.diff_horizontal_scroll <= app.visibleBodyTextMaxHorizontalScroll());

    app.scrollDiffHorizontal(-1);
    try std.testing.expect(app.viewer.diff_horizontal_scroll <= app.visibleBodyTextMaxHorizontalScroll());
}

test "layout changes reset horizontal scroll only when diff pane width changes" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{
            .display_mode = .side_by_side,
            .diff_horizontal_scroll = 16,
        },
    };

    app.toggleSidebarVisibility();
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);

    app.viewer.diff_horizontal_scroll = 16;
    app.adjustSidebarWidth(-1);
    try std.testing.expectEqual(@as(usize, 16), app.viewer.diff_horizontal_scroll);

    app.toggleSidebarVisibility();
    app.viewer.diff_horizontal_scroll = 16;
    app.adjustSidebarWidth(-1);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);
}

test "search resync without pane width change keeps horizontal scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{
            .display_mode = .side_by_side,
            .sidebar_hidden = true,
        },
    };

    setDiffSearchQuery(&app, "wide");
    app.submitSearch();
    app.viewer.diff_horizontal_scroll = 16;

    app.adjustSidebarWidth(-1);

    try std.testing.expectEqual(@as(usize, 16), app.viewer.diff_horizontal_scroll);
}

test "side-by-side context horizontal clamp checks both columns" {
    const line = diff_parser.DiffLine{
        .kind = .context,
        .text = "0123456789012345678901234567890123456789",
        .old_line = 1,
        .new_line = 1,
    };

    try std.testing.expectEqual(
        @as(usize, 8),
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, true),
    );
    try std.testing.expect(
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, false) <
            maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80, true),
    );
}

test "display mode and search navigation reset horizontal scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 120, .height = 8 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{
            .display_mode = .unified,
            .diff_horizontal_scroll = 16,
        },
    };

    try app.update(.toggle_display_mode, undefined);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);

    app.viewer.diff_horizontal_scroll = 16;
    setDiffSearchQuery(&app, "wide");
    app.submitSearch();
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);
}

test "line number toggle clamps horizontal scroll without changing vertical scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 8 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_scroll = 2,
            .diff_horizontal_scroll = 999,
        },
    };

    const old_scroll = app.viewer.diff_scroll;
    try app.update(.toggle_line_numbers, undefined);

    try std.testing.expect(!app.viewer.view_options.line_numbers);
    try std.testing.expectEqual(old_scroll, app.viewer.diff_scroll);
    try std.testing.expect(app.viewer.diff_horizontal_scroll <= app.visibleBodyTextMaxHorizontalScroll());
}

test "display mode toggle keeps nearby vertical scroll position" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .diff_scroll = 8,
            .sidebar_hidden = true,
        },
    };
    app.viewer.diff_cursor = app.selectedCoordinateAtOffset(app.viewer.diff_scroll) orelse app.viewer.diff_cursor;

    try app.update(.toggle_display_mode, undefined);

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.effectiveDisplayMode());
    try std.testing.expect(app.viewer.diff_scroll > 0);
    try std.testing.expect(app.viewer.diff_scroll <= app.selectedFileLineIndex(app.effectiveDisplayMode()).lineCount());
}

test "display mode toggle brings cursor back into view after wheel scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_scroll = 12,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };

    try std.testing.expect(app.visibleDiffCursorOffset() == null);

    try app.update(.toggle_display_mode, undefined);

    try std.testing.expect(app.visibleDiffCursorOffset() != null);
}

test "mouse diff scroll keeps cursor in the viewport" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_scroll = 12,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };

    try std.testing.expect(app.visibleDiffCursorOffset() == null);

    app.scrollDiff(1);

    try std.testing.expect(app.visibleDiffCursorOffset() != null);
}

test "diff cursor initialization skips hidden metadata rows" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffMetadataOnly()),
    };

    app.initializeDiffCursorForSelectedFile();

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 1 }, app.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
}

test "diff cursor initialization selects binary marker after hidden metadata" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffBinaryOnly()),
    };

    app.initializeDiffCursorForSelectedFile();

    try std.testing.expectEqual(diff_view_model.BodyCoordinate.binary_marker, app.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.visibleDiffCursorOffset());
}

test "diff scroll keeps visible cursor screen position stable" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_scroll = 3,
        },
    };
    const old_scroll = app.viewer.diff_scroll;
    const old_offset = old_scroll + 1;
    app.viewer.diff_cursor = app.selectedCoordinateAtOffset(old_offset) orelse return error.ExpectedCoordinate;

    app.scrollDiff(1);

    const new_offset = app.selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    try std.testing.expectEqual(old_offset - old_scroll, new_offset - app.viewer.diff_scroll);
}

test "diff scroll syncs invisible cursor to scrolloff margin" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    };
    const line_count = app.selectedFileLineIndex(app.effectiveDisplayMode()).lineCount();
    const visible_rows = app.diffVisibleRows();
    const margin = @min(@as(usize, 8), visible_rows / 3);

    app.viewer.diff_scroll = 0;
    app.viewer.diff_cursor = app.selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;
    app.scrollDiff(-1);
    try std.testing.expectEqual(app.viewer.diff_scroll + margin, app.selectedDiffCursorOffset().?);

    app.viewer.diff_scroll = line_count - visible_rows;
    app.viewer.diff_cursor = app.selectedCoordinateAtOffset(0) orelse return error.ExpectedCoordinate;
    app.scrollDiff(1);
    try std.testing.expectEqual(app.viewer.diff_scroll + visible_rows - 1 -| margin, app.selectedDiffCursorOffset().?);
}

test "diff row movement continues from wheel-synced visible cursor" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    };
    const line_count = app.selectedFileLineIndex(app.effectiveDisplayMode()).lineCount();
    app.viewer.diff_scroll = 0;
    app.viewer.diff_cursor = app.selectedCoordinateAtOffset(line_count - 1) orelse return error.ExpectedCoordinate;

    app.scrollDiff(-1);
    const synced_offset = app.selectedDiffCursorOffset() orelse return error.ExpectedCursorOffset;
    app.moveDiffCursorRows(1);

    try std.testing.expectEqual(synced_offset + 1, app.selectedDiffCursorOffset().?);
}

test "mouse wheel routes through diff scroll cursor sync" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .focus = .sidebar,
            .diff_scroll = 12,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };

    try app.update(.mouse_diff_wheel_down, undefined);

    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expect(app.visibleDiffCursorOffset() != null);
}

test "diff scroll cursor sync keeps search state" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
            .diff_scroll = 12,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };
    setDiffSearchQuery(&app, "late new");
    app.submitSearch();
    const old_match = app.search.match orelse return error.ExpectedSearchMatch;
    const old_match_offset = app.search.match_offset;

    app.scrollDiff(1);

    try std.testing.expect(std.meta.eql(old_match, app.search.match.?));
    try std.testing.expectEqual(old_match_offset, app.search.match_offset);
}

test "display mode scroll remap preserves hunk-local ratio" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var loaded = testLoadedDiffOne();
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(loaded),
        .viewer = .{
            .display_mode = .unified,
            .sidebar_hidden = true,
        },
    };

    const old_index = app.selectedFileLineIndex(.unified);
    const old_scroll = old_index.hunkOffset(0) + 3;
    const new_scroll = app.remapDiffScrollForModeChange(.unified, .side_by_side, old_scroll);

    const hunk_index = old_index.hunkIndexAtOffset(old_scroll) orelse return error.ExpectedHunkOffset;
    const new_index = app.selectedFileLineIndex(.side_by_side);
    const old_local = old_scroll - old_index.hunkOffset(hunk_index);
    const expected_local = old_local * (new_index.hunkLineCount(hunk_index) - 1) / (old_index.hunkLineCount(hunk_index) - 1);
    try std.testing.expectEqual(new_index.hunkOffset(hunk_index) + expected_local, new_scroll);
}

test "hidden sidebar keeps tab from changing focus" {
    var app: App = .{
        .viewer = .{
            .focus = .diff,
            .sidebar_hidden = true,
        },
    };

    try app.update(.toggle_focus, undefined);

    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
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

test "opening amend confirmation cancels active discard confirmation" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.cancelAmendConfirmation(std.testing.allocator);
    defer app.cancelDiscardConfirmation(std.testing.allocator);

    app.discard_confirmation = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .path = try std.testing.allocator.dupe(u8, "src/app.zig"),
    };
    app.overlay.openDiscardFile();
    app.commit_panel.open(.amend);
    app.commit_panel.insert('x');

    try app.openAmendConfirmation(std.testing.allocator, "/repo");

    try std.testing.expect(app.discard_confirmation == null);
    try std.testing.expect(app.amend_confirmation != null);
    try std.testing.expectEqual(OverlayKind.amend_commit, app.overlay.kind);
}

test "canceling amend confirmation keeps commit panel draft" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.cancelAmendConfirmation(std.testing.allocator);

    app.commit_panel.open(.amend);
    app.commit_panel.insert('x');
    try app.openAmendConfirmation(std.testing.allocator, "/repo");

    app.cancelAmendConfirmation(std.testing.allocator);

    try std.testing.expect(app.amend_confirmation == null);
    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expect(app.commit_panel.is_open);
    try std.testing.expectEqual(app_commit_panel.Mode.amend, app.commit_panel.mode);
    try std.testing.expectEqualStrings("x", app.commit_panel.subject.slice());
}

test "prompt input stays above help overlay" {
    var app: App = .{
        .search = .{ .mode = true },
    };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedPromptInput;
    try app.update(msg, undefined);

    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expectEqualStrings("?", app.search.input.slice());
}

test "mouse click focuses sidebar and diff panes" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .focus = .diff },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const sidebar_event = testMouseEvent(content.col + 1, content.row + 2, .left);
    const sidebar_msg = app.handleEvent(sidebar_event) orelse return error.ExpectedSidebarMouseMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);

    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.viewer.sidebar_width) + 1;
    const diff_event = testMouseEvent(diff_col, content.row + 2, .left);
    const diff_msg = app.handleEvent(diff_event) orelse return error.ExpectedDiffMouseMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
}

test "mouse click selects sidebar file rows" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = testLoadState(testLoadedDiffTwo()),
        .viewer = .{ .focus = .diff },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const row = content.row + sidebar_header_rows + 1;
    const msg = app.handleEvent(testMouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "mouse click toggles sidebar directory rows" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = testLoadStateWithArena(arena, testLoadedDiffNested()),
        .viewer = .{ .focus = .diff, .selected_node = 1, .selected_file = 0 },
    };
    defer app.clearLoadedDiff();

    const content = app_view.shellContentRect(app.terminal_size);
    const row = content.row + sidebar_header_rows;
    const msg = app.handleEvent(testMouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarDirectoryClickMessage;
    try app.update(msg, undefined);

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
}

test "mouse click on sidebar header or blank body focuses only" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .focus = .diff },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const header_msg = app.handleEvent(testMouseEvent(content.col + 1, content.row + 1, .left)) orelse return error.ExpectedSidebarHeaderClickMessage;
    try app.update(header_msg, undefined);
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);

    app.viewer.focus = .diff;
    const blank_row = content.row + sidebar_header_rows + 2;
    const blank_msg = app.handleEvent(testMouseEvent(content.col + 1, blank_row, .left)) orelse return error.ExpectedSidebarBlankClickMessage;
    try app.update(blank_msg, undefined);
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
}

test "mouse click uses filtered sidebar projection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var loaded = testLoadedDiffTwoWithStatuses();
    loaded.reviewed_files = try arena.allocator().alloc(bool, loaded.document.files.len);
    @memset(loaded.reviewed_files, false);
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .deleted);

    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = testLoadStateWithArena(arena, loaded),
        .viewer = .{ .focus = .diff, .selected_node = 0, .selected_file = 0 },
        .review_display = .{ .changed_file_filter = .deleted },
    };
    defer app.clearLoadedDiff();

    const content = app_view.shellContentRect(app.terminal_size);
    const row = content.row + sidebar_header_rows;
    const msg = app.handleEvent(testMouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedFilteredSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "mouse wheel scrolls the pane under the pointer" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffTwo()),
        .viewer = .{ .focus = .diff },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const sidebar_msg = app.handleEvent(testMouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedSidebarWheelMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);

    app.selectFileAbsolute(0);
    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.viewer.sidebar_width) + 1;
    const diff_msg = app.handleEvent(testMouseEvent(diff_col, content.row + 2, .wheel_down)) orelse return error.ExpectedDiffWheelMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expect(app.viewer.diff_scroll > 0);
}

test "mouse uses full body as diff pane while sidebar is hidden" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{
            .focus = .sidebar,
            .sidebar_hidden = true,
        },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const msg = app.handleEvent(testMouseEvent(content.col + 1, content.row + 2, .left)) orelse return error.ExpectedHiddenSidebarMouseMessage;
    try app.update(msg, undefined);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
}

test "help overlay wheel scrolls help and ignores clicks" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .overlay = .{ .kind = .help },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const msg = app.handleEvent(testMouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedHelpWheelMessage;
    try std.testing.expectEqual(App.Msg.help_scroll_down, msg);
    try app.update(msg, undefined);
    try std.testing.expect(app.overlay.help_scroll > 0);

    try std.testing.expect(app.handleEvent(testMouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "mouse horizontal wheel scrolls diff pane horizontally" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 12 },
        .load = testLoadState(testLoadedDiffWide()),
        .viewer = .{
            .focus = .sidebar,
            .display_mode = .unified,
        },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.viewer.sidebar_width) + 1;
    const msg = app.handleEvent(testMouseEvent(diff_col, content.row + 2, .wheel_right)) orelse return error.ExpectedHorizontalWheelMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expect(app.viewer.diff_horizontal_scroll > 0);
}

test "mouse events are ignored outside body and prompt modes" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
    };

    try std.testing.expect(app.handleEvent(testMouseEvent(-1, 1, .left)) == null);

    const content = app_view.shellContentRect(app.terminal_size);
    const footer_row: i16 = @intCast(content.row + terminalBodyHeight(app.layoutSize().height));
    try std.testing.expect(app.handleEvent(testMouseEvent(content.col + 1, footer_row, .left)) == null);

    app.search.mode = true;
    try std.testing.expect(app.handleEvent(testMouseEvent(content.col + 1, content.row + 1, .left)) == null);
}

test "mouse release and motion events are ignored" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
    };

    const content = app_view.shellContentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(testMouseEventTyped(content.col + 1, content.row + 1, .left, .release)) == null);
    try std.testing.expect(app.handleEvent(testMouseEventTyped(content.col + 1, content.row + 1, .left, .motion)) == null);
}

test "mode change resyncs search match to rendered body offsets" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 14 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .display_mode = .unified },
    };
    setDiffSearchQuery(&app, "late new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.search.match_offset);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
    try std.testing.expect(app.search.match_offset.? >= app.viewer.diff_scroll);
    try std.testing.expect(app.search.match_offset.? < app.viewer.diff_scroll + app.diffVisibleRows());
}

test "mode change keeps search near later matches" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .display_mode = .unified },
    };
    setDiffSearchQuery(&app, "new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.search.match_offset);
    app.selectSearchMatch(.forward);
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 9), app.search.match_offset);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
}

test "toggle selected hunk fold updates active rendered line cache" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = testLoadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(arena, loaded),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer app.clearLoadedDiff();

    try std.testing.expectEqual(@as(usize, 10), app.selectedFileLineIndex(.unified).lineCount());
    app.toggleSelectedHunkFold();

    const active = app.loadedDiff().?;
    try std.testing.expect(active.isHunkFolded(0, 0));
    try std.testing.expectEqual(@as(usize, 5), app.selectedFileLineIndex(.unified).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 4), app.selectedFileLineIndex(.side_by_side).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .side_by_side).hunkLineCount(0));
}

test "search unfolds folded hunk body matches before setting offset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = testLoadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);
    loaded.setHunkFolded(0, 0, true);

    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(arena, loaded),
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");

    app.submitSearch();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.search.match_offset);
}

test "manual fold keeps hunk open when it contains active search match" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const allocator = arena.allocator();
    var loaded = testLoadedDiffOne();
    loaded.collapsed_hunks = try allocator.alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    loaded.rendered_line_cache = try diff_view_model.RenderedLineCache.build(allocator, loaded.document);

    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(arena, loaded),
    };
    defer app.clearLoadedDiff();
    setDiffSearchQuery(&app, "new");
    app.submitSearch();

    app.toggleSelectedHunkFold();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.search.match_offset);
}

test "file change resyncs retained search query to selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffTwo()),
        .viewer = .{ .display_mode = .unified },
    };
    setDiffSearchQuery(&app, "target");

    app.selectFileAbsolute(1);

    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
    try expectSearchCoordinate(&app, .{ .metadata = 0 });
    try std.testing.expectEqual(@as(?usize, 0), app.search.match_offset);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_scroll);
}

test "sidebar navigation can select directories without changing selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffNested()),
        .viewer = .{
            .selected_file = 0,
            .selected_node = 1,
        },
    };

    app.selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);

    app.selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);

    app.selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "sidebar navigation keeps status-only target through clamp" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffOne()),
        .viewer = .{
            .selected_file = 0,
            .selected_node = 0,
        },
    };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/status-only.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);
    try app.applyStatusProjection(std.testing.allocator, false);

    const loaded = app.loadedDiff().?;
    const status_node = blk: {
        for (loaded.tree.nodes, 0..) |node, index| {
            switch (node.target) {
                .status_entry => break :blk index,
                else => {},
            }
        }
        return error.ExpectedStatusOnlyNode;
    };

    app.selectSidebarNode(loaded, status_node);
    app.clampSelection(loaded.document.files.len);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.viewer.selected_target.?);
    try std.testing.expect(app.selectedFileIndex(loaded) == null);
    try std.testing.expect(app.selectedStatusEntry() != null);
}

test "sidebar navigation moves between status-only nodes" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a.zig\x00?? b.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);
    try app.createStatusOnlyLoadedSession(std.testing.allocator, app.git_status.document);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.viewer.selected_target.?);
    const first_node = app.viewer.selected_node;

    app.selectFileDelta(1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 1 }, app.viewer.selected_target.?);
    try std.testing.expect(app.viewer.selected_node != first_node);

    app.selectFileDelta(-1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.viewer.selected_target.?);
    try std.testing.expectEqual(first_node, app.viewer.selected_node);
}

test "pending selection restore waits for status projection after stage" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_file = 0,
            .selected_node = 0,
        },
    };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.clearPendingSelectionRestore(std.testing.allocator);

    try app.setPendingSelectionRestore(std.testing.allocator, "b");
    app.status_load_pending = 1;

    // Diff reload can finish before the status reload. In that intermediate
    // tree the staged file is absent, so do not consume the pending restore yet.
    try app.applyStatusProjection(std.testing.allocator, false);
    try std.testing.expect(app.pending_selection_restore != null);

    app.status_load_pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.git_status.replace("/repo", &status_bundle);
    try app.applyStatusProjection(std.testing.allocator, false);

    try std.testing.expect(app.pending_selection_restore == null);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.viewer.selected_target.?);
}

test "staged summary distinguishes pending missing and ready status snapshots" {
    var app: App = .{
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.git_status.deinit();

    try std.testing.expectEqual(app_commit_panel.StagedSummary.unavailable, app.stagedSummaryForActiveRepo());

    app.status_load_pending = 1;
    try std.testing.expectEqual(app_commit_panel.StagedSummary.loading_or_stale, app.stagedSummaryForActiveRepo());

    app.status_load_pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  staged.zig\x00 M unstaged.zig\x00?? new.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);

    try std.testing.expectEqual(app_commit_panel.StagedSummary{ .ready = .{ .count = 1 } }, app.stagedSummaryForActiveRepo());
}

test "pending selection restore survives status projection while diff reload is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffTwo()),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
            .selected_node = 1,
        },
    };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.clearPendingSelectionRestore(std.testing.allocator);

    try app.setPendingSelectionRestore(std.testing.allocator, "b");
    app.load.pending = .{ .diff_load = app.load.generation + 1 };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.git_status.replace("/repo", &status_bundle);
    try app.applyStatusProjection(std.testing.allocator, false);

    try std.testing.expect(app.pending_selection_restore != null);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
}

test "pending selection restore clears when status finishes empty after reload" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_file = 0,
            .selected_node = 0,
        },
        .status_load_generation = 7,
    };
    defer app.clearLoadedDiff();
    defer app.clearPendingSelectionRestore(std.testing.allocator);

    try app.setPendingSelectionRestore(std.testing.allocator, "missing.zig");

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishStatusLoad(&ctx, .{
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(app.pending_selection_restore == null);
}

test "manual reload clears action selection restore" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
    };
    defer app.clearPendingSelectionRestore(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.setPendingSelectionRestore(std.testing.allocator, "src/main.zig");

    try app.update(.reload, &ctx);

    try std.testing.expect(app.pending_selection_restore == null);
}

test "toggling selected directory collapses visible descendants" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffNested()),
        .viewer = .{
            .selected_file = 0,
            .selected_node = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleSelectedDirectory();

    const loaded = app.load.state.loaded.loaded;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), loaded.tree.visibleNodeCount(&loaded.collapsed_dirs));
    try std.testing.expect(loaded.visible_nodes.len >= loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
}

test "file search selects matching file and expands ancestors" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffNested()),
        .viewer = .{
            .selected_file = 0,
            .selected_node = 0,
        },
        .file_search = .{ .mode = true },
    };
    defer app.clearLoadedDiff();

    var loaded = app.loadedDiff().?;
    try file_tree.collapse(app.loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setFileSearchInput(&app, "src/b");

    try app.submitFileSearch(std.testing.allocator);

    loaded = app.loadedDiff().?;
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
    try std.testing.expect(!app.file_search.mode);
}

test "file search keeps prompt open on no match" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffNested()),
        .file_search = .{ .mode = true },
    };
    setFileSearchInput(&app, "missing");

    defer app.file_search.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search.mode);
    try std.testing.expect(app.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
}

test "file search skips hidden reviewed matches" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .file_search = .{ .mode = true },
        .review_display = .{ .hide_reviewed_files = true },
    };
    defer app.clearLoadedDiff();
    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, true, .all);
    setFileSearchInput(&app, "src");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search.mode);
    try std.testing.expect(!app.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "file search trims empty input and restores focus on cancel" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadState(testLoadedDiffNested()),
        .viewer = .{ .focus = .diff },
    };

    app.enterFileSearchMode();
    try std.testing.expectEqual(Focus.sidebar, app.viewer.focus);
    setFileSearchInput(&app, "   ");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search.mode);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
}

test "file search keeps diff focus while sidebar is hidden" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffNested()),
        .viewer = .{ .focus = .diff, .sidebar_hidden = true },
    };
    defer app.clearLoadedDiff();

    app.enterFileSearchMode();
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    setFileSearchInput(&app, "   ");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search.mode);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);

    app.enterFileSearchMode();
    setFileSearchInput(&app, "src/b");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search.mode);
    try std.testing.expectEqual(Focus.diff, app.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "sidebar renders file status badges" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = testLoadState(testLoadedDiffTwoWithStatuses()),
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(4, sidebar_header_rows, "A");
    try ts.expectCellText(4, sidebar_header_rows + 1, "D");
}

test "sidebar renders mode change badge next to file status" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "script.sh",
            .path = "script.sh",
            .depth = 0,
            .target = .{ .diff_file = 0 },
            .status = .modified,
            .mode_changed = true,
        },
    };
    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = testLoadState(.{
            .text = "",
            .document = .{ .files = &test_files_one },
            .tree = .{ .nodes = &nodes },
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(2, sidebar_header_rows, "M");
    try ts.expectCellText(4, sidebar_header_rows, "m");
}

test "sidebar title indicates active focus" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .focus = .sidebar },
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(0, 0, " ");
    try ts.expectCellText(1, 0, "F");
    try std.testing.expect(ts.surface.readCell(1, 0).?.style.fg.eql(.{ .index = 14 }));
    try std.testing.expect(!ts.surface.readCell(1, 0).?.style.reverse);
}

test "diff header detail row draws neutral separator" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .focus = .diff },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(0, 1, "─");
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.gray));
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.dim);
}

test "selectionContext exposes selected diff file model coordinate" {
    const app: App = .{
        .config = .{ .source = .{ .range = "main...HEAD" } },
        .load = testLoadState(testLoadedDiffTwo()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_file = 0,
            .diff_cursor = .{ .hunk_header = 1 },
        },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "gitframe",
            .display_path = ".",
            .canonical_root = "/repo/gitframe",
        } } },
    };

    const selection = app.selectionContext();
    try std.testing.expectEqualStrings("/repo/gitframe", selection.repo_root.?);
    try std.testing.expectEqual(context.SourceKind.range, selection.source.kind);
    try std.testing.expectEqualStrings("main...HEAD", selection.source.detail.?);

    const diff_selection = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), diff_selection.file_index);
    try std.testing.expectEqualStrings("a", diff_selection.display_path);
    try std.testing.expectEqualStrings("a", diff_selection.path_key.?);
    try std.testing.expectEqual(@as(?usize, 1), diff_selection.hunk_index);
}

test "selectionContext accepts status-only target shape" {
    const app: App = .{
        .config = .{ .source = .stdin },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 2 } },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.stdin, selection.source.kind);

    const status_selection = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 2), status_selection.status_index);
    try std.testing.expect(status_selection.path_key == null);
}

test "selectedStagePathKey accepts diff and status-only selections" {
    var app: App = .{
        .load = testLoadState(testLoadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };

    try std.testing.expectEqualStrings("src/added.zig", app.selectedStagePathKey().?);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    defer app.git_status.deinit();
    try app.git_status.replace("/repo", &status_bundle);
    app.viewer.selected_target = .{ .status_only = 0 };

    try std.testing.expectEqualStrings("src/new.zig", app.selectedStagePathKey().?);
}

test "selectedStageTarget skips only fresh staged-only files" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer app.git_status.deinit();

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try app.git_status.replace("/repo", &staged_bundle);
    switch (app.selectedStageTarget()) {
        .already_staged => |path| try std.testing.expectEqualStrings("src/added.zig", path),
        else => return error.ExpectedAlreadyStagedTarget,
    }

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "AM src/added.zig\x00");
    try app.git_status.replace("/repo", &mixed_bundle);
    switch (app.selectedStageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src/added.zig", target.path);
        },
        else => return error.ExpectedMixedStageTarget,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU src/added.zig\x00");
    try app.git_status.replace("/repo", &conflict_bundle);
    switch (app.selectedStageTarget()) {
        .ready => {},
        else => return error.ExpectedConflictStageTarget,
    }

    app.status_load_pending = 1;
    switch (app.selectedStageTarget()) {
        .ready => {},
        else => return error.ExpectedStaleStatusStageTarget,
    }
    app.status_load_pending = null;

    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try app.git_status.replace("/other", &other_repo_bundle);
    switch (app.selectedStageTarget()) {
        .ready => {},
        else => return error.ExpectedMismatchedStatusStageTarget,
    }

    app.config.source = .cached;
    switch (app.selectedStageTarget()) {
        .unavailable_source => {},
        else => return error.ExpectedCachedStageUnavailable,
    }
}

test "selectedUnstageTarget requires fresh staged status" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer app.git_status.deinit();

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try app.git_status.replace("/repo", &staged_bundle);

    switch (app.selectedUnstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src/added.zig", target.path);
        },
        else => return error.ExpectedReadyUnstageTarget,
    }

    app.config.source = .cached;
    switch (app.selectedUnstageTarget()) {
        .ready => {},
        else => return error.ExpectedCachedUnstageTarget,
    }

    app.config.source = .{ .range = "main...HEAD" };
    switch (app.selectedUnstageTarget()) {
        .unavailable_source => {},
        else => return error.ExpectedUnavailableUnstageSource,
    }
    app.config.source = .unstaged;

    app.status_load_pending = 1;
    switch (app.selectedUnstageTarget()) {
        .stale_status => {},
        else => return error.ExpectedStaleUnstageStatus,
    }
    app.status_load_pending = null;

    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try app.git_status.replace("/other", &other_repo_bundle);
    switch (app.selectedUnstageTarget()) {
        .stale_status => {},
        else => return error.ExpectedMismatchedUnstageStatus,
    }

    var unstaged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/added.zig\x00");
    try app.git_status.replace("/repo", &unstaged_bundle);
    switch (app.selectedUnstageTarget()) {
        .no_staged_content => {},
        else => return error.ExpectedNoStagedContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU src/added.zig\x00");
    try app.git_status.replace("/repo", &conflict_bundle);
    switch (app.selectedUnstageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqualStrings("src/added.zig", target.path);
            try std.testing.expect(target.kind == .file);
        },
        else => return error.ExpectedConflictUnstageTarget,
    }
}

test "selectedHunkUnstageTarget requires a visible session-staged hunk" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer app.staged_hunks.deinit(std.testing.allocator);

    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedHunk,
    }

    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.patch.len > 0);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }

    app.viewer.diff_scroll = 100;
    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .offscreen_cursor => {},
        else => return error.ExpectedOffscreenHunkUnstageTarget,
    }
}

test "combined projection target is requested for mixed modified unstaged files" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer app.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.git_status.replace("/repo", &mixed_bundle);

    const target = app.reviewProjectionTarget() orelse return error.ExpectedCombinedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.combined_hunks, target.kind);
    try std.testing.expectEqual(app_review_projection.SourceKind.unstaged, target.source_kind);
    try std.testing.expectEqualStrings("/repo", target.repo_root);
    try std.testing.expectEqualStrings("a", target.path_key);

    app.config.source = .cached;
    try std.testing.expect(app.reviewProjectionTarget() == null);
}

test "active diff display uses ready combined projection by identity" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = .{ .generation = 7, .state = .{ .loaded = testLoadedSession(testLoadedDiffOne()) } },
        .status_load_generation = 3,
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer app.git_status.deinit();
    defer app.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.git_status.replace("/repo", &mixed_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.load.generation,
        app.status_load_generation,
    );
    app.review_projection = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    var frame_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer frame_arena.deinit();
    const display = (try app.activeDiffDisplay(frame_arena.allocator(), .unified)) orelse return error.ExpectedActiveDisplay;
    try std.testing.expect(display == .combined_projection);
    try std.testing.expectEqual(@as(usize, 2), display.combined_projection.file.hunks.len);
    try std.testing.expectEqual(@as(usize, 2), display.combined_projection.staged_flags.len);
    try std.testing.expect(display.combined_projection.staged_flags[0]);
    try std.testing.expect(!display.combined_projection.staged_flags[1]);
}

test "projected hunk actions route through original cached and unstaged origins" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = .{ .generation = 7, .state = .{ .loaded = testLoadedSession(testLoadedDiffOne()) } },
        .status_load_generation = 3,
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer app.git_status.deinit();
    defer app.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.git_status.replace("/repo", &mixed_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.load.generation,
        app.status_load_generation,
    );
    app.review_projection = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    switch (app.selectedHunkStageTarget(std.testing.allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedProjectedHunk,
    }
    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expectEqual(app_actions.HunkMarkSource.projection, target.mark_source);
        },
        else => return error.ExpectedReadyProjectedUnstage,
    }

    app.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (app.selectedHunkStageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 1), target.hunk_index);
            try std.testing.expectEqual(app_actions.HunkMarkSource.projection, target.mark_source);
        },
        else => return error.ExpectedReadyProjectedStage,
    }
    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedProjectedHunk,
    }
}

test "stagedHunkFlagsForFile keeps partial staged display flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
    };
    defer app.staged_hunks.deinit(std.testing.allocator);
    defer app.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.git_status.replace("/repo", &status_bundle);
    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);

    const flags = try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expect(flags[0]);
    try std.testing.expect(!flags[1]);
}

test "stagedHunkFlagsForFile normalizes all staged hunks only when status is staged-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
    };
    defer app.staged_hunks.deinit(std.testing.allocator);
    defer app.git_status.deinit();

    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.git_status.replace("/repo", &staged_bundle);
    try std.testing.expectEqual(@as(usize, 0), (try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks)).len);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.git_status.replace("/repo", &mixed_bundle);
    const mixed_flags = try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), mixed_flags.len);
    try std.testing.expect(mixed_flags[0]);
    try std.testing.expect(mixed_flags[1]);

    app.status_load_pending = 1;
    const stale_flags = try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), stale_flags.len);
    try std.testing.expect(stale_flags[0]);
    try std.testing.expect(stale_flags[1]);

    app.status_load_pending = null;
    var other_repo_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.git_status.replace("/other", &other_repo_bundle);
    const missing_flags = try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks);
    try std.testing.expectEqual(@as(usize, 2), missing_flags.len);
    try std.testing.expect(missing_flags[0]);
    try std.testing.expect(missing_flags[1]);
}

test "stagedHunkFlagsForFile display normalization does not clear hunk action marks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 10 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer app.staged_hunks.deinit(std.testing.allocator);
    defer app.git_status.deinit();

    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    try app.staged_hunks.add(std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.git_status.replace("/repo", &staged_bundle);
    try std.testing.expectEqual(@as(usize, 0), (try app.stagedHunkFlagsForFile(arena.allocator(), test_file_with_hunks)).len);

    switch (app.selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }
}

test "hunk action results mutate session staged marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
    };
    defer app.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = app.actions.begin(.stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .result = .ok,
    });

    try std.testing.expect(app.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 1), app.staged_hunks.items.items.len);

    const unstage_pending = app.actions.begin(.unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .result = .ok,
    });

    try std.testing.expect(!app.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 0), app.staged_hunks.items.items.len);
}

test "projection hunk action results reload status without mutating session marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
    };
    defer app.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = app.actions.begin(.stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .mark_source = .projection,
        .result = .ok,
    });

    try std.testing.expect(!app.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 0), app.staged_hunks.items.items.len);
    try std.testing.expect(app.status_load_pending != null);
    clearPendingStatusTasks(&ctx, allocator);

    try app.staged_hunks.add(allocator, "/repo", "a", 1);
    const unstage_pending = app.actions.begin(.unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .mark_source = .projection,
        .result = .ok,
    });

    try std.testing.expect(app.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 1), app.staged_hunks.items.items.len);
    try std.testing.expect(app.status_load_pending != null);
}

test "clearLoadedDiff clears session staged hunk marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffOne()),
    };
    defer app.staged_hunks.deinit(allocator);

    try app.staged_hunks.add(allocator, "/repo", "a", 0);
    try std.testing.expect(app.staged_hunks.contains("/repo", "a", 0));

    app.clearLoadedDiff();

    try std.testing.expectEqual(@as(usize, 0), app.staged_hunks.items.items.len);
}

test "directory stage target uses sidebar cursor and status subtree" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffNested()),
        .viewer = .{
            // The diff pane still points at a file, but the sidebar cursor is
            // on the directory. Directory actions must use the cursor target.
            .selected_target = .{ .diff_file = 1 },
            .selected_node = 0,
        },
    };
    defer app.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00M  other.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);

    switch (app.selectedStageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryStageTarget,
    }

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00");
    try app.git_status.replace("/repo", &staged_bundle);
    switch (app.selectedStageTarget()) {
        .no_stageable_content => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedNoDirectoryStageableContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00UU src/b\x00");
    try app.git_status.replace("/repo", &conflict_bundle);
    switch (app.selectedStageTarget()) {
        .conflict_unsupported => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedDirectoryConflictStageReject,
    }
}

test "directory unstage target scans staged subtree" {
    var app: App = .{
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .load = testLoadState(testLoadedDiffNested()),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_node = 0,
        },
    };
    defer app.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00AM src/b\x00 M other.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);

    switch (app.selectedUnstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryUnstageTarget,
    }

    var unstaged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00");
    try app.git_status.replace("/repo", &unstaged_bundle);
    switch (app.selectedUnstageTarget()) {
        .no_staged_content => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedNoDirectoryStagedContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00UU src/b\x00");
    try app.git_status.replace("/repo", &conflict_bundle);
    switch (app.selectedUnstageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryConflictUnstageReject,
    }
}

test "pending selection restore can restore directory nodes" {
    var app: App = .{
        .load = testLoadState(testLoadedDiffNested()),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_node = 1,
        },
    };
    defer app.clearPendingSelectionRestore(std.testing.allocator);

    try app.setPendingSelectionRestore(std.testing.allocator, "src");
    var loaded = testLoadedDiffNested();

    try std.testing.expect(app.restorePendingSelectionOrFallback(std.testing.allocator, &loaded));
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.viewer.selected_target.?);
}

test "selectionContext keeps no-index source paths" {
    const app: App = .{
        .config = .{ .source = .{ .no_index = .{ .left = "before.zig", .right = "after.zig" } } },
    };

    const selection = app.selectionContext();
    try std.testing.expectEqual(context.SourceKind.no_index, selection.source.kind);
    try std.testing.expectEqualStrings("difftool", selection.source.label);
    try std.testing.expect(selection.source.detail == null);
    try std.testing.expectEqualStrings("before.zig", selection.source.left_path.?);
    try std.testing.expectEqualStrings("after.zig", selection.source.right_path.?);
    try std.testing.expect(selection.selected == null);
}

test "selectionContext returns null selected without a target" {
    const app: App = .{
        .config = .{ .source = .unstaged },
        .viewer = .{ .selected_target = null },
    };

    const selection = app.selectionContext();
    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.unstaged, selection.source.kind);
    try std.testing.expectEqualStrings("unstaged changes", selection.source.label);
    try std.testing.expect(selection.selected == null);
}

test "initialSelectionContext selects first diff file and hunk" {
    const loaded = testLoadedDiffTwo();
    const selection = App.initialSelectionContext(.{ .patch_file = "changes.diff" }, null, &loaded);

    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.patch_file, selection.source.kind);
    try std.testing.expectEqualStrings("changes.diff", selection.source.detail.?);

    const file = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), file.file_index);
    try std.testing.expectEqualStrings("a", file.path_key.?);
    try std.testing.expectEqual(@as(?usize, 0), file.hunk_index);
}

test "activeRootFromDiscovery rejects ambiguous workspace export" {
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "one", .display_path = "one", .canonical_root = "/work/one" },
        .{ .label = "two", .display_path = "two", .canonical_root = "/work/two" },
    };

    try std.testing.expectError(error.AmbiguousWorkspaceExport, App.activeRootFromDiscovery(.{ .workspace = .{
        .current_root = "/work",
        .repos = &repos,
    } }));
}

test "diff search row keeps active focus style" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .focus = .diff },
    };
    setDiffSearchQuery(&app, "missing");

    try app.viewDiffPane(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(1, 1, "s");
    const style = ts.surface.readCell(1, 1).?.style;
    try std.testing.expect(style.bold);
    try std.testing.expect(!style.reverse);
}

test "changed file filter keeps only matching status rows" {
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffTwoWithStatuses()),
        .review_display = .{ .changed_file_filter = .added },
        .viewer = .{
            .selected_node = 1,
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
        },
    };
    defer app.clearLoadedDiff();

    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, false, app.review_display.changed_file_filter);

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
}

test "finishDiffLoad applies active changed file filter" {
    var app: App = .{
        .load = .{ .generation = 1 },
        .review_display = .{ .changed_file_filter = .added },
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, test_diff_added_deleted);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 1), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(file_tree.Status.added, loaded.tree.nodes[1].status.?);
}

test "cycling changed file filter rebuilds visible nodes and reconciles selection" {
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), testLoadedDiffTwoWithStatuses()),
        .viewer = .{
            .selected_node = 1,
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
        },
    };
    defer app.clearLoadedDiff();

    try app.cycleChangedFileFilter();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.review_display.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "file search skips files outside active changed filter" {
    var app: App = .{
        .load = testLoadState(testLoadedDiffTwoWithStatuses()),
        .file_search = .{ .mode = true },
        .review_display = .{ .changed_file_filter = .added },
    };
    setFileSearchInput(&app, "deleted");
    defer app.file_search.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search.mode);
    try std.testing.expect(app.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
}

test "toggleReviewedFile toggles selected diff target" {
    var reviewed = [_]bool{ false, false };
    var app: App = .{
        .load = testLoadState(.{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 0,
            .selected_file = 0,
        },
    };
    defer app.reviewed_store.deinit(std.testing.allocator);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);

    app.viewer.selected_node = 1;
    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
}

test "toggleReviewedFile uses selected target while cursor is on directory" {
    var reviewed = [_]bool{ false, false };
    var app: App = .{
        .load = testLoadState(.{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 0,
            .selected_target = .{ .diff_file = 1 },
            .selected_file = 1,
        },
    };
    defer app.reviewed_store.deinit(std.testing.allocator);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &reviewed);
}

test "toggleReviewedFile ignores unkeyable files in repository input" {
    const unkeyable_files = [_]diff_parser.FileDiff{.{
        .header = "metadata only",
        .old_path = null,
        .new_path = null,
        .metadata = &.{},
        .hunks = &.{},
    }};
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "metadata", .path = "metadata", .depth = 0, .target = .{ .diff_file = 0 } },
    };
    var reviewed = [_]bool{false};
    var app: App = .{
        .load = testLoadState(.{
            .text = "",
            .document = .{ .files = &unkeyable_files },
            .tree = .{ .nodes = &nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "repo",
            .canonical_root = "/repo",
        } } },
    };

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{false}, &reviewed);
}

test "raw reviewed state stays in active load only" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .load = testLoadState(testLoadedDiffTwo()),
        .viewer = .{
            .selected_node = 0,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);

    var loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.load.state.loaded.reviewed_files_owned = true;

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);

    app.clearLoadedDiff();
    app.load.state = .{ .loaded = testLoadedSession(testLoadedDiffTwo()) };
    loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.load.state.loaded.reviewed_files_owned = true;

    try std.testing.expectEqualSlices(bool, &.{ false, false }, loaded.reviewed_files);
}

test "reviewed state is scoped by active repository root" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "one"),
        .display_path = try allocator.dupe(u8, "one"),
        .canonical_root = try allocator.dupe(u8, "/work/one"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "two"),
        .display_path = try allocator.dupe(u8, "two"),
        .canonical_root = try allocator.dupe(u8, "/work/two"),
    };

    var app: App = .{
        .allocator = allocator,
        .repo_state = .{ .discovery = .{ .workspace = .{
            .current_root = try allocator.dupe(u8, "/work"),
            .repos = repos,
        } } },
    };
    defer app.repo_state.deinit(allocator);
    defer app.reviewed_store.deinit(allocator);

    try app.reviewed_store.set(allocator, app.activeRepoRoot(), test_files_two[0], true);

    var loaded_one = testLoadedDiffTwo();
    try app.materializeReviewedFiles(allocator, &loaded_one);
    defer allocator.free(loaded_one.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded_one.reviewed_files);

    app.repo_state.active_index = 1;
    var loaded_two = testLoadedDiffTwo();
    try app.materializeReviewedFiles(allocator, &loaded_two);
    defer allocator.free(loaded_two.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, loaded_two.reviewed_files);
}

test "repo picker focuses active workspace repository" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "one"),
        .display_path = try allocator.dupe(u8, "one"),
        .canonical_root = try allocator.dupe(u8, "/work/one"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "two"),
        .display_path = try allocator.dupe(u8, "two"),
        .canonical_root = try allocator.dupe(u8, "/work/two"),
    };

    var app: App = .{
        .repo_state = .{
            .discovery = .{ .workspace = .{
                .current_root = try allocator.dupe(u8, "/work"),
                .repos = repos,
            } },
            .active_index = 1,
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.list.focusedIndex());
}

test "repo picker opens for a single repository" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "repo"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("repo", app.repo_picker.list.filter.labels[0]);
}

test "repo picker path input uses separate prompt mode" {
    var app: App = .{ .repo_picker = .{ .mode = true } };

    app.enterRepoPickerPathInput();

    try std.testing.expectEqual(app_prompt.RepoPickerMode.path_input, app.repo_picker.prompt_mode);
}

test "workspace path discovery keeps picker open for explicit repo selection" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "chasen"),
        .display_path = try allocator.dupe(u8, "chasen"),
        .canonical_root = try allocator.dupe(u8, "/work/chasen"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "gitframe"),
        .display_path = try allocator.dupe(u8, "gitframe"),
        .canonical_root = try allocator.dupe(u8, "/work/gitframe"),
    };

    var app: App = .{
        .repo_picker = .{ .mode = true, .prompt_mode = .path_input },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "current"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/current/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.clearRepoPickerDiscovery(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.acceptRepoPathDiscovery(&ctx, .{ .workspace = .{
        .current_root = try allocator.dupe(u8, "/work"),
        .repos = repos,
    } });

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(app_prompt.RepoPickerMode.list, app.repo_picker.prompt_mode);
    try std.testing.expectEqualStrings("/current/repo", app.repo_state.activeRoot().?);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("chasen", app.repo_picker.list.filter.labels[0]);
    try std.testing.expectEqualStrings("gitframe", app.repo_picker.list.filter.labels[1]);
}

test "closed repo picker rejects stale path discovery result after reopen" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "current"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/current/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.clearRepoPickerDiscovery(allocator);
    defer app.deinitRepoPickerItems(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const old_generation = app.repo_picker.beginPathDiscovery();
    app.cancelRepoPickerMode(allocator);
    try app.enterRepoPickerMode(allocator);
    const new_generation = app.repo_picker.beginPathDiscovery();

    var stale = RepoPathDiscoveryFinished{
        .generation = old_generation,
        .submitted_path = try allocator.dupe(u8, "/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/old/repo"),
        } } },
    };
    try app.finishRepoPathDiscovery(&ctx, stale);
    stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expect(new_generation != old_generation);
    try std.testing.expectEqualStrings("/current/repo", app.repo_state.activeRoot().?);
}

test "expandUserPath expands current user's home shorthand" {
    const allocator = std.testing.allocator;
    const home = "/home/tester";

    const bare_home = try expandUserPath(allocator, "~", home);
    defer allocator.free(bare_home);
    try std.testing.expectEqualStrings(home, bare_home);

    const child = try expandUserPath(allocator, "~/dev/repo", home);
    defer allocator.free(child);
    try std.testing.expectEqualStrings("/home/tester/dev/repo", child);

    const named_user = try expandUserPath(allocator, "~someone/repo", home);
    defer allocator.free(named_user);
    try std.testing.expectEqualStrings("~someone/repo", named_user);
}

test "repo switch clears action selection restore" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "one"),
        .display_path = try allocator.dupe(u8, "one"),
        .canonical_root = try allocator.dupe(u8, "/work/one"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "two"),
        .display_path = try allocator.dupe(u8, "two"),
        .canonical_root = try allocator.dupe(u8, "/work/two"),
    };

    var app: App = .{
        .allocator = allocator,
        .repo_state = .{
            .discovery = .{ .workspace = .{
                .current_root = try allocator.dupe(u8, "/work"),
                .repos = repos,
            } },
            .active_index = 0,
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    defer app.clearPendingSelectionRestore(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.setPendingSelectionRestore(allocator, "src/main.zig");
    try app.enterRepoPickerMode(allocator);

    try app.submitRepoPicker(&ctx);

    try std.testing.expect(app.pending_selection_restore == null);
}

test "sidebar renders reviewed marker" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    var reviewed = [_]bool{ true, false };
    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = testLoadState(.{
            .text = "",
            .document = .{ .files = &test_files_two_statuses },
            .tree = .{ .nodes = &test_tree_two_status_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(1, sidebar_header_rows, "✓");
    try ts.expectCellText(4, sidebar_header_rows, "A");
}

test "hide reviewed files removes reviewed file rows from visible list" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expect(app.review_display.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "hide reviewed files removes directories with no visible file descendants" {
    var reviewed = [_]bool{ true, true };
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
}

test "hide reviewed files keeps directories for non-contiguous unreviewed descendants" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_non_contiguous_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 4), loaded.visibleNodeAt(1));
}

test "marking a visible file as reviewed while hidden moves selection" {
    var reviewed = [_]bool{ false, false };
    var app: App = .{
        .load = testLoadStateWithArena(.init(std.testing.allocator), .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
        .review_display = .{ .hide_reviewed_files = true },
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);
    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, true, .all);

    try app.toggleReviewedFile(std.testing.allocator);

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "search match marker is drawn on visible match row" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = testLoadState(testLoadedDiffOne()),
        .search = .{ .match_offset = 4 },
        .viewer = .{ .diff_scroll = 3 },
    };

    app.drawSearchMatchMarker(&ts.surface);

    try ts.expectCellText(0, diff_body_start_row + 1, "»");
}

test "search marker gutter does not overwrite diff content" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = testLoadState(testLoadedDiffOne()),
        .search = .{ .match_offset = 0 },
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(0, diff_body_start_row, "»");
    try ts.expectCellText(1, diff_body_start_row, "▌");
    try ts.expectCellText(2, diff_body_start_row, "▾");
}

test "status mode label uses diff content width after marker gutter" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(72, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 72, .height = 9 },
        .load = testLoadState(testLoadedDiffOne()),
        .viewer = .{ .display_mode = .side_by_side },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(41, 0, "u");
    try ts.expectCellText(42, 0, "n");
    try ts.expectCellText(43, 0, "i");
    try ts.expectCellText(49, 0, "(");
    try ts.expectCellText(50, 0, "a");
}

test "search input header does not show no match before submit" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = testLoadState(testLoadedDiffOne()),
        .search = .{ .mode = true },
    };
    setDiffSearchInput(&app, "missing");

    try app.viewDiffPane(&ts.surface, app.load.state.loaded.loaded);

    try ts.expectCellText(1, 1, "s");
    try ts.expectCellText(9, 1, "m");
    try ts.expectCellText(16, 1, " ");
}

test "canceling edited search restores committed query and match" {
    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = testLoadState(testLoadedDiffOne()),
        .search = .{
            .match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
            .match_offset = 4,
        },
    };
    setDiffSearchQuery(&app, "new");

    app.enterSearchMode();
    app.search.input.backspace();
    try app.search.input.insert('x');
    app.cancelSearchMode();

    try std.testing.expectEqualStrings("new", app.search.query.slice());
    try std.testing.expectEqualStrings("new", app.search.input.slice());
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 4), app.search.match_offset);
}

test "load empty state shows actionable no changes message" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(82, 18);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 82, .height = 18 },
        .load = .{ .state = .{ .empty = .no_changes } },
    };

    try app.view(&ts.surface);

    try expectSnapshotContains(&ts, "No changes");
    try expectSnapshotContains(&ts, "Press r to reload or q to quit.");
}

test "load empty state distinguishes missing repository" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 18 },
        .load = .{ .state = .{ .empty = .no_repository } },
    };

    try app.view(&ts.surface);

    try expectSnapshotContains(&ts, "No Git repository");
    try expectSnapshotContains(&ts, "Press q to quit.");
}

test "load failed state shows first error line and retry hint" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 90, .height = 18 },
    };
    defer app.clearLoadedDiff();
    try app.load.replaceFailed(std.testing.allocator, "git diff failed\nsecond line");

    try app.view(&ts.surface);

    try expectSnapshotContains(&ts, "Could not load diff");
    try expectSnapshotContains(&ts, "git diff failed");
    try expectSnapshotContains(&ts, "Press r to retry or q to quit.");
    try expectSnapshotNotContains(&ts, "second line");
}

test "loaded diff with empty visible filter shows local empty state" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = testLoadedDiffTwoWithStatuses();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .binary);

    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 18 },
        .load = testLoadStateWithArena(arena, loaded),
        .review_display = .{ .changed_file_filter = .binary },
    };
    defer app.clearLoadedDiff();

    try app.view(&ts.surface);

    try expectSnapshotContains(&ts, "No files match current filters");
    try expectSnapshotContains(&ts, "Press F to change filter or r to reload.");
}

test "load runtime pending tracks task kind and generation" {
    var load: LoadRuntimeState = .{};

    const discovery_generation = load.beginRepoDiscovery();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(discovery_generation));
    try std.testing.expect(!load.finishPending(.{ .diff_load = discovery_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.finishPending(.{ .repo_discovery = discovery_generation }));
    try std.testing.expect(!load.hasPending());

    const diff_generation = load.beginDiffLoad();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(diff_generation));
    try std.testing.expect(load.clearPendingIfCurrent(.{ .diff_load = diff_generation }));
    try std.testing.expect(!load.hasPending());
}

test "load runtime keeps newer pending when stale task finishes" {
    var load: LoadRuntimeState = .{};

    const stale_generation = load.beginDiffLoad();
    const current_generation = load.beginDiffLoad();

    try std.testing.expect(!load.finishPending(.{ .diff_load = stale_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(current_generation));
    try std.testing.expect(load.finishPending(.{ .diff_load = current_generation }));
    try std.testing.expect(!load.hasPending());
}

test "finishDiffLoad takes current loaded bundle ownership" {
    var app: App = .{ .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, test_diff_one);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.load.state == .loaded);
    try std.testing.expect(app.load.state.loaded.loaded.document.files.len > 0);
    try std.testing.expectEqual(@as(usize, 1), app.load.state.loaded.loaded.document.files.len);
}

test "finishDiffLoad initially selects first visible file node" {
    var app: App = .{ .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = testLoadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_node);
}

test "finishDiffLoad initially selects first visible file after status projection" {
    var app: App = .{ .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.git_status.replace("/repo", &status_bundle);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = testLoadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.viewer.selected_target.?);
}

test "finishDiffLoad keeps initial visible selection intent for later status projection" {
    var app: App = .{
        .load = .{ .generation = 1 },
        .status_load_generation = 7,
        .status_load_pending = 7,
    };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = testLoadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pending_initial_first_visible_selection);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.finishStatusLoad(&ctx, .{
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    try std.testing.expect(!app.pending_initial_first_visible_selection);

    const loaded = app.activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.viewer.selected_target.?);
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: App = .{ .load = .{ .generation = 2 } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, test_diff_one);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.load.state == .idle);
}

test "finishDiffLoad records empty diff as no changes" {
    var app: App = .{ .load = .{ .generation = 1 } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .empty,
    });

    try std.testing.expect(app.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.load.state.empty);
    try std.testing.expectEqual(@as(u64, 1), app.load.generation);
}

test "finishDiffLoad projects earlier status snapshot into empty diff" {
    var app: App = .{ .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    defer app.git_status.deinit();
    defer app.tree_order.deinit(std.testing.allocator);
    defer if (app.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.git_status.replace("/tmp/repo", &status_bundle);

    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .empty,
    });

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.tree.nodes[1].target.status_entry);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.viewer.selected_target);
}

test "finishRepoDiscovery records no repository as empty state" {
    var app: App = .{ .load = .{ .generation = 1 } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer app.repo_state.deinit(std.testing.allocator);

    try app.finishRepoDiscovery(&ctx, .{
        .generation = 1,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try std.testing.allocator.dupe(u8, "/work"),
        } } },
    });

    try std.testing.expect(app.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_repository, app.load.state.empty);
}

test "finishDiffLoad copies and frees current failed message" {
    var app: App = .{ .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const message = try std.testing.allocator.dupe(u8, " failed \n");
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .failed = message },
    });

    try std.testing.expect(app.load.state == .failed);
    try std.testing.expectEqualStrings("failed", app.load.state.failed.message);
}

test "finishDiffLoad failure clears pending selection restore" {
    var app: App = .{ .allocator = std.testing.allocator, .load = .{ .generation = 1 } };
    defer app.clearLoadedDiff();
    defer app.clearPendingSelectionRestore(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.setPendingSelectionRestore(std.testing.allocator, "src/main.zig");

    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .failed_static = "failed" },
    });

    try std.testing.expect(app.pending_selection_restore == null);
}

fn expectSearchCoordinate(app: *const App, expected: diff_view_model.BodyCoordinate) !void {
    try std.testing.expect(app.search.match != null);
    try std.testing.expect(std.meta.eql(expected, app.search.match.?.coordinate));
}

fn expectSnapshotContains(ts: *const chasen.testing.TestSurface, needle: []const u8) !void {
    const actual = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, needle) != null);
}

fn expectSnapshotNotContains(ts: *const chasen.testing.TestSurface, needle: []const u8) !void {
    const actual = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, needle) == null);
}

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.search.query.buffer[0..query.len], query);
    app.search.query.len = query.len;
    app.search.query.cursor = query.len;
    setDiffSearchInput(app, query);
}

fn setDiffSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.search.input.buffer[0..query.len], query);
    app.search.input.len = query.len;
    app.search.input.cursor = query.len;
}

fn setFileSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.file_search.input.buffer[0..query.len], query);
    app.file_search.input.len = query.len;
    app.file_search.input.cursor = query.len;
}

fn testMouseEvent(col: anytype, row: anytype, button: anytype) chasen.Event {
    return testMouseEventTyped(col, row, button, .press);
}

fn testMouseEventTyped(col: anytype, row: anytype, button: anytype, mouse_type: anytype) chasen.Event {
    return .{ .mouse = .{
        .col = @intCast(col),
        .row = @intCast(row),
        .button = button,
        .mods = .{},
        .type = mouse_type,
    } };
}

fn clearPendingStatusTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    // finishStageHunk queues a status refresh. These tests assert the App-side
    // state transition only, so clean up the queued task context explicitly.
    for (ctx.pendingTaskWithSlice()) |entry| {
        const task: *StatusLoadTask = @ptrCast(@alignCast(entry.ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
    ctx.pending_tasks_with_len = 0;
}

fn testLoadedSession(loaded: LoadedDiff) LoadedSession {
    return .{
        .arena = .init(std.testing.allocator),
        .loaded = loaded,
        .reviewed_files_owned = false,
    };
}

fn testLoadState(loaded: LoadedDiff) LoadRuntimeState {
    return .{ .state = .{ .loaded = testLoadedSession(loaded) } };
}

fn testLoadStateWithArena(arena: std.heap.ArenaAllocator, loaded: LoadedDiff) LoadRuntimeState {
    return .{ .state = .{ .loaded = .{
        .arena = arena,
        .loaded = loaded,
        .reviewed_files_owned = false,
    } } };
}

fn testLoadedDiffOne() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_one },
        .tree = .{ .nodes = &test_tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffTwo() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_two },
        .tree = .{ .nodes = &test_tree_two_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffNested() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_two },
        .tree = .{ .nodes = &test_tree_nested_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffTwoWithStatuses() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_two_statuses },
        .tree = .{ .nodes = &test_tree_two_status_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffFileOneFirst() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_two },
        .tree = .{ .nodes = &test_tree_file_one_first_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffWide() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_wide },
        .tree = .{ .nodes = &test_tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffMetadataOnly() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_metadata_only },
        .tree = .{ .nodes = &test_tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testLoadedDiffBinaryOnly() LoadedDiff {
    return .{
        .text = "",
        .document = .{ .files = &test_files_binary_only },
        .tree = .{ .nodes = &test_tree_one_nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
}

fn testCombinedHunkBundle(allocator: std.mem.Allocator) !app_review_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, test_diff_cached_projection);
    errdefer cached_bundle.deinit();

    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, test_diff_unstaged_projection);
    errdefer unstaged_bundle.deinit();

    var projection_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer projection_arena.deinit();
    const projection = try diff_hunk_projection.build(
        projection_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );

    return .{
        .arena = projection_arena,
        .projection = projection,
        .cached_bundle = cached_bundle,
        .unstaged_bundle = unstaged_bundle,
    };
}

const test_tree_one_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
};

const test_tree_two_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
};

const test_tree_file_one_first_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .target = .{ .diff_file = 1 } },
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
};

const test_tree_nested_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .target = .{ .diff_file = 1 } },
};

const test_tree_non_contiguous_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .directory, .name = "lib", .path = "lib", .depth = 0 },
    .{ .kind = .file, .name = "c", .path = "lib/c", .depth = 1, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .target = .{ .diff_file = 1 } },
};

const test_tree_two_status_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "added.zig", .path = "src/added.zig", .depth = 1, .target = .{ .diff_file = 0 }, .status = .added },
    .{ .kind = .file, .name = "deleted.zig", .path = "src/deleted.zig", .depth = 1, .target = .{ .diff_file = 1 }, .status = .deleted },
};

const test_files_one = [_]diff_parser.FileDiff{
    test_file_with_hunks,
};

const test_files_two = [_]diff_parser.FileDiff{
    test_file_with_hunks,
    test_file_with_target_metadata,
};

const test_files_two_statuses = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/src/added.zig b/src/added.zig",
        .old_path = null,
        .new_path = "b/src/added.zig",
        .metadata = &.{"new file mode 100644"},
        .hunks = &.{},
    },
    .{
        .header = "diff --git a/src/deleted.zig b/src/deleted.zig",
        .old_path = "a/src/deleted.zig",
        .new_path = null,
        .metadata = &.{"deleted file mode 100644"},
        .hunks = &.{},
    },
};

const test_files_wide = [_]diff_parser.FileDiff{
    test_file_wide,
};

const test_files_metadata_only = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{ "index 1..2", "old mode 100644" },
        .hunks = &.{},
    },
};

const test_files_binary_only = [_]diff_parser.FileDiff{
    .{
        .header = "diff --git a/bin b/bin",
        .old_path = "a/bin",
        .new_path = "b/bin",
        .metadata = &.{"index 1..2"},
        .hunks = &.{},
        .is_binary = true,
    },
};

const test_file_wide = diff_parser.FileDiff{
    .header = "diff --git a/a b/a",
    .old_path = "a/a",
    .new_path = "b/a",
    .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
    .hunks = &.{.{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = "wide",
        .lines = &.{.{
            .kind = .context,
            .text = "wide-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            .old_line = 1,
            .new_line = 1,
        }},
    }},
};

const test_diff_one =
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -1,3 +1,3 @@
    \\ one
    \\-old
    \\+new
    \\ two
    \\
;

const test_diff_added_deleted =
    \\diff --git a/src/added.zig b/src/added.zig
    \\new file mode 100644
    \\--- /dev/null
    \\+++ b/src/added.zig
    \\@@ -0,0 +1 @@
    \\+added
    \\diff --git a/src/deleted.zig b/src/deleted.zig
    \\deleted file mode 100644
    \\--- a/src/deleted.zig
    \\+++ /dev/null
    \\@@ -1 +0,0 @@
    \\-deleted
    \\
;

const test_diff_cached_projection =
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -10,3 +10,3 @@
    \\ context
    \\-old staged
    \\+new staged
    \\ context
    \\
;

const test_diff_unstaged_projection =
    \\diff --git a/a b/a
    \\index 2..3 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -20,3 +20,3 @@
    \\ context
    \\-old unstaged
    \\+new unstaged
    \\ context
    \\
;

const test_file_with_hunks = diff_parser.FileDiff{
    .header = "diff --git a/a b/a",
    .old_path = "a/a",
    .new_path = "b/a",
    .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
    .hunks = &test_hunks,
};

const test_hunks = [_]diff_parser.Hunk{
    .{
        .old_start = 1,
        .old_count = 5,
        .new_start = 1,
        .new_count = 5,
        .section = "first",
        .lines = &test_hunk_first_lines,
    },
    .{
        .old_start = 20,
        .old_count = 3,
        .new_start = 20,
        .new_count = 3,
        .section = "second",
        .lines = &test_hunk_second_lines,
    },
};

const test_hunk_first_lines = [_]diff_parser.DiffLine{
    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
    .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
    .{ .kind = .removed, .text = "old", .old_line = 3 },
    .{ .kind = .added, .text = "new", .new_line = 3 },
    .{ .kind = .context, .text = "four", .old_line = 4, .new_line = 4 },
};

const test_hunk_second_lines = [_]diff_parser.DiffLine{
    .{ .kind = .context, .text = "late one", .old_line = 20, .new_line = 20 },
    .{ .kind = .removed, .text = "late old", .old_line = 21 },
    .{ .kind = .added, .text = "late new", .new_line = 21 },
};

const test_file_with_target_metadata = diff_parser.FileDiff{
    .header = "diff --git a/b b/b",
    .old_path = "a/b",
    .new_path = "b/b",
    .metadata = &.{"target metadata"},
    .hunks = &.{},
};

fn testFileWithHunks() diff_parser.FileDiff {
    return test_file_with_hunks;
}

fn testFileWithTargetMetadata() diff_parser.FileDiff {
    return test_file_with_target_metadata;
}
