const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_input = @import("app_input.zig");
const app_load = @import("app_load.zig");
const app_view = @import("app_view.zig");
const diff_parser = @import("diff_parser.zig");
const diff_file = @import("diff_file.zig");
const diff_render = @import("diff_render.zig");
const diff_search = @import("diff_search.zig");
const diff_source = @import("diff_source.zig");
const diff_view_model = @import("diff_view_model.zig");
const editor = @import("editor.zig");
const file_tree = @import("file_tree.zig");
const loaded_diff = @import("loaded_diff.zig");
const repo_discovery = @import("repo_discovery.zig");
const repo_state = @import("repo_state.zig");
const review_state = @import("review_state.zig");

const auto_reload_timer_id = "gitframe.auto_reload";
const auto_reload_interval_ns = 2 * std.time.ns_per_s;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(App.Msg);
const Focus = app_input.Focus;
const LoadedDiff = loaded_diff.LoadedDiff;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(App.Msg);

const MousePane = enum {
    sidebar,
    diff,
};

const MousePoint = struct {
    col: u16,
    row: u16,
};

const ViewerState = struct {
    /// Sticky file shown in the diff pane. Directory sidebar rows can be
    /// selected without changing this value.
    selected_file: usize = 0,
    /// Sidebar cursor. This may point at either a directory node or a file node.
    selected_node: usize = 0,
    focus: Focus = .sidebar,
    sidebar_hidden: bool = false,
    sidebar_width: ?u16 = null,
    diff_scroll: usize = 0,
    diff_horizontal_scroll: usize = 0,
    selected_hunk: usize = 0,
    display_mode: diff_render.DisplayMode = .side_by_side,
};

const DiffSearchState = struct {
    mode: bool = false,
    input: SearchQuery = .{},
    query: SearchQuery = .{},
    match: ?diff_search.Match = null,
    /// Rendered body-line offset cache for match. Recomputed when display
    /// mode, fold state, or selected file changes.
    match_offset: ?usize = null,
};

const FilterPromptState = struct {
    mode: bool = false,
    input: SearchQuery = .{},
    /// Owns filtered indexes while labels are borrowed from the active source.
    filter: ui.ListFilter = .{},
    no_match: bool = false,
};

const PendingLoad = union(enum) {
    repo_discovery: u64,
    diff_load: u64,

    fn generation(self: PendingLoad) u64 {
        return switch (self) {
            .repo_discovery => |value| value,
            .diff_load => |value| value,
        };
    }
};

const LoadRuntimeState = struct {
    state: LoadState = .idle,
    pending: ?PendingLoad = null,
    active_reviewed_files_owned: bool = false,
    /// Owns the currently loaded raw diff, parsed document arrays, and error
    /// messages. Recreated on every successful load/reload.
    arena: ?std.heap.ArenaAllocator = null,
    /// Monotonic id used to ignore stale async task results after reload.
    generation: u64 = 0,

    fn beginRepoDiscovery(self: *LoadRuntimeState) u64 {
        const next = self.nextGeneration();
        self.pending = .{ .repo_discovery = next };
        return next;
    }

    fn beginDiffLoad(self: *LoadRuntimeState) u64 {
        const next = self.nextGeneration();
        self.pending = .{ .diff_load = next };
        return next;
    }

    fn finishPending(self: *LoadRuntimeState, expected: PendingLoad) bool {
        if (!self.pendingMatches(expected)) return false;
        self.pending = null;
        return true;
    }

    fn clearPendingIfCurrent(self: *LoadRuntimeState, expected: PendingLoad) bool {
        return self.finishPending(expected);
    }

    fn isCurrent(self: *const LoadRuntimeState, generation: u64) bool {
        return self.generation == generation;
    }

    fn hasPending(self: *const LoadRuntimeState) bool {
        return self.pending != null;
    }

    fn nextGeneration(self: *LoadRuntimeState) u64 {
        self.generation +%= 1;
        return self.generation;
    }

    fn pendingMatches(self: *const LoadRuntimeState, expected: PendingLoad) bool {
        const pending = self.pending orelse return false;
        return std.meta.eql(pending, expected);
    }
};

pub const App = struct {
    config: CliConfig = .{},
    env_map: ?*std.process.Environ.Map = null,
    allocator: ?std.mem.Allocator = null,
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    load: LoadRuntimeState = .{},
    status_message_buf: [160]u8 = undefined,
    status_message: []const u8 = "",
    viewer: ViewerState = .{},
    search: DiffSearchState = .{},
    file_search: FilterPromptState = .{},
    file_search_return_focus: Focus = .sidebar,
    repo_picker: FilterPromptState = .{},
    hide_reviewed_files: bool = false,
    changed_file_filter: ChangedFileFilter = .all,
    repo_state: repo_state.State = .{},
    /// Session-level source of truth for reviewed files. The active LoadedDiff
    /// keeps a materialized bool slice so hide-reviewed hot paths stay O(1).
    reviewed_store: review_state.Store = .{},

    pub const Msg = union(enum) {
        terminal_resized: chasen.Size,
        repos_discovered: RepoDiscoveryFinished,
        diff_loaded: DiffLoadFinished,
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
        mouse_sidebar_wheel_up,
        mouse_sidebar_wheel_down,
        mouse_diff_wheel_up,
        mouse_diff_wheel_down,
        mouse_diff_wheel_left,
        mouse_diff_wheel_right,
        toggle_display_mode,
        enter_search,
        cancel_search,
        clear_search,
        submit_search,
        search_insert: u21,
        search_backspace,
        select_next_search_match,
        select_previous_search_match,
        enter_file_search,
        cancel_file_search,
        submit_file_search,
        file_search_insert: u21,
        file_search_backspace,
        enter_repo_picker,
        cancel_repo_picker,
        submit_repo_picker,
        repo_picker_insert: u21,
        repo_picker_backspace,
        repo_picker_move_previous,
        repo_picker_move_next,
        toggle_reviewed_file,
        toggle_hide_reviewed_files,
        cycle_changed_file_filter,
        open_selected_file_in_editor,
        editor_finished: chasen.ForegroundCommandResult,
        reload,
        auto_reload_tick,
        quit,
    };

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
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
        self.file_search.filter.deinit(deinit_ctx.allocator);
        self.repo_picker.filter.deinit(deinit_ctx.allocator);
        self.reviewed_store.deinit(deinit_ctx.allocator);
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
            },
            .repos_discovered => |finished| try self.finishRepoDiscovery(ctx, finished),
            .diff_loaded => |finished| try self.finishDiffLoad(ctx, finished),
            .select_previous_file => self.selectFileDelta(-1),
            .select_next_file => self.selectFileDelta(1),
            .toggle_directory => try self.toggleSelectedDirectory(),
            .expand_directory => try self.expandSelectedDirectory(),
            .collapse_or_parent_directory => try self.collapseOrSelectParentDirectory(),
            .scroll_diff_up => self.scrollDiff(-1),
            .scroll_diff_down => self.scrollDiff(1),
            .scroll_diff_left => self.scrollDiffHorizontal(-1),
            .scroll_diff_right => self.scrollDiffHorizontal(1),
            .page_diff_up => self.pageDiff(-1),
            .page_diff_down => self.pageDiff(1),
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
                self.viewer.display_mode = self.viewer.display_mode.toggled();
                self.resetDiffHorizontalScroll();
                self.clampDiffNavigationKeepingHunkVisible();
                self.updateSearchMatchOffset();
                self.scrollSearchMatchIntoView();
                self.clampDiffNavigation();
            },
            .enter_search => self.enterSearchMode(),
            .cancel_search => self.cancelSearchMode(),
            .clear_search => self.clearSearch(),
            .submit_search => self.submitSearch(),
            .search_insert => |codepoint| self.search.input.insert(codepoint) catch {},
            .search_backspace => self.search.input.backspace(),
            .select_next_search_match => self.selectSearchMatch(.forward),
            .select_previous_search_match => self.selectSearchMatch(.backward),
            .enter_file_search => self.enterFileSearchMode(),
            .cancel_file_search => self.cancelFileSearchMode(ctx.allocator()),
            .submit_file_search => try self.submitFileSearch(ctx.allocator()),
            .file_search_insert => |codepoint| {
                self.file_search.no_match = false;
                self.file_search.input.insert(codepoint) catch {};
            },
            .file_search_backspace => {
                self.file_search.no_match = false;
                self.file_search.input.backspace();
            },
            .enter_repo_picker => try self.enterRepoPickerMode(ctx.allocator()),
            .cancel_repo_picker => self.cancelRepoPickerMode(ctx.allocator()),
            .submit_repo_picker => try self.submitRepoPicker(ctx),
            .repo_picker_insert => |codepoint| {
                self.repo_picker.no_match = false;
                self.repo_picker.input.insert(codepoint) catch {};
                try self.refreshRepoPickerFilter(ctx.allocator());
            },
            .repo_picker_backspace => {
                self.repo_picker.no_match = false;
                self.repo_picker.input.backspace();
                try self.refreshRepoPickerFilter(ctx.allocator());
            },
            .repo_picker_move_previous => self.repo_picker.filter.update(.move_prev),
            .repo_picker_move_next => self.repo_picker.filter.update(.move_next),
            .toggle_reviewed_file => try self.toggleReviewedFile(ctx.allocator()),
            .toggle_hide_reviewed_files => try self.toggleHideReviewedFiles(),
            .cycle_changed_file_filter => try self.cycleChangedFileFilter(),
            .open_selected_file_in_editor => try self.openSelectedFileInEditor(ctx),
            .editor_finished => |result| try self.finishEditorCommand(ctx, result),
            .reload => switch (self.config.source) {
                .stdin => ctx.redraw().skip(),
                else => {
                    if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
                        try self.startRepoDiscovery(ctx);
                    } else {
                        try self.startDiffLoad(ctx);
                    }
                },
            },
            .auto_reload_tick => try self.autoReloadTick(ctx),
            .quit => ctx.quit(),
        }
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
        if (self.search.mode or self.file_search.mode or self.repo_picker.mode) return null;
        if (mouse.type != .press) return null;

        const pane = self.mousePane(mouse) orelse return null;
        return switch (mouse.button) {
            .left => switch (pane) {
                .sidebar => .focus_sidebar,
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
            .repo_picker_mode = self.repo_picker.mode,
            .search_query_len = self.search.query.len,
            .focus = self.viewer.focus,
            .sidebar_hidden = self.viewer.sidebar_hidden,
        };
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
            self.load.state = .{ .failed = "Could not start repo discovery task" };
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
                result = .empty;
                self.repo_state.replace(ctx.allocator(), discovery);

                if (self.activeRepoRoot() == null) {
                    self.clearLoadedDiff();
                    self.load.state = .{ .empty = .no_repository };
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

    fn startDiffLoad(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const repo_root = self.repoRootForCurrentSource() catch |err| {
            self.load.state = .{ .empty = switch (err) {
                error.MissingRepoRoot => .no_repository,
            } };
            return;
        };

        try self.startDiffLoadWithRepoRoot(ctx, repo_root, true);
    }

    fn startDiffLoadWithRepoRoot(self: *App, ctx: *chasen.Ctx(Msg), repo_root: ?[]const u8, clear_visible_state: bool) !void {
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
            self.load.state = .{ .failed = "Could not start diff load task" };
            return err;
        };
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

        if (self.config.source == .stdin) {
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
        self.status_message = std.fmt.bufPrint(&self.status_message_buf, fmt, args) catch "status formatting failed";
    }

    fn autoReloadTick(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (!self.config.watch) return;
        if (self.config.source == .stdin) return;
        if (self.repo_picker.mode or self.search.mode or self.file_search.mode) {
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

        // Multiple reloads can be in flight. Only the newest generation is
        // allowed to update visible state.
        _ = self.load.finishPending(.{ .diff_load = finished.generation });
        if (!self.load.isCurrent(finished.generation)) return;

        self.clearLoadedDiff();

        switch (result) {
            .empty => self.load.state = .{ .empty = .no_changes },
            .loaded => |*bundle| {
                var loaded = bundle.loaded;
                var arena = bundle.takeArena();
                errdefer arena.deinit();

                try self.materializeReviewedFiles(ctx.allocator(), &loaded);
                errdefer ctx.allocator().free(loaded.reviewed_files);

                if (self.hide_reviewed_files or self.changed_file_filter != .all) {
                    try loaded.rebuildVisibleNodes(arena.allocator(), self.hide_reviewed_files, self.changed_file_filter);
                }

                // Keep all fallible setup above this point. After assigning
                // load.state, clearLoadedDiff owns the materialized reviewed
                // slice and load arena.
                self.load.arena = arena;
                self.load.state = .{ .loaded = loaded };
                self.load.active_reviewed_files_owned = true;

                const active_loaded = self.activeLoadedDiff().?;
                self.syncSidebarNodeToSelectedFile(active_loaded);
                self.clampSelection(active_loaded.document.files.len);
                if (self.hide_reviewed_files) {
                    self.reconcileSelectionAfterVisibleNodeChange(active_loaded);
                }
                self.clampDiffNavigation();
                self.refreshSearchForSelectedFile();
            },
            .failed => |message| {
                try self.storeFailedMessage(ctx.allocator(), std.mem.trim(u8, message, " \t\r\n"));
            },
            .failed_static => |message| {
                try self.storeFailedMessage(ctx.allocator(), message);
            },
        }
    }

    fn storeFailedMessage(self: *App, allocator: std.mem.Allocator, message: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();

        const copied = try arena.allocator().dupe(u8, message);
        self.load.arena = arena;
        self.load.state = .{ .failed = if (copied.len > 0) copied else "Unknown diff load error" };
    }

    fn clearLoadedDiff(self: *App) void {
        if (self.load.active_reviewed_files_owned) {
            if (self.allocator) |allocator| {
                if (self.activeLoadedDiff()) |loaded| allocator.free(loaded.reviewed_files);
            }
        }
        self.load.active_reviewed_files_owned = false;
        if (self.load.arena) |*arena| arena.deinit();
        self.load.arena = null;
        self.load.state = .idle;
        self.viewer.diff_scroll = 0;
        self.viewer.diff_horizontal_scroll = 0;
        self.viewer.selected_hunk = 0;
        self.clearSearchMatch();
    }

    fn selectFileDelta(self: *App, delta: i2) void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (loaded.document.files.len == 0 or loaded.tree.nodes.len == 0) return;

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
        if (self.viewer.selected_file == target) {
            if (self.activeLoadedDiff()) |loaded| {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            self.clampSelection(file_count);
            return;
        }
        self.viewer.selected_file = target;
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
        const previous_file = self.viewer.selected_file;
        self.viewer.selected_node = node_index;
        // File rows change the active diff pane file. Directory rows only move
        // the sidebar cursor and keep the previous file visible.
        if (loaded.tree.nodes[node_index].file_index) |file_index| {
            self.viewer.selected_file = file_index;
            if (self.viewer.selected_file != previous_file) {
                self.resetDiffPosition();
                self.refreshSearchForSelectedFile();
            }
        }
    }

    fn toggleSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind != .directory) return;
        const allocator = self.loadArenaAllocator() orelse return;
        try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(allocator, self.hide_reviewed_files, self.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn expandSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind != .directory) return;
        file_tree.expand(&loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.hide_reviewed_files, self.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn collapseOrSelectParentDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.viewer.selected_node];
        if (node.kind == .directory and !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) {
            const allocator = self.loadArenaAllocator() orelse return;
            try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path);
            try loaded.rebuildVisibleNodes(allocator, self.hide_reviewed_files, self.changed_file_filter);
            self.clampSelection(loaded.document.files.len);
            return;
        }
        if (parentDirectoryNodeIndex(loaded.tree, self.viewer.selected_node)) |parent| {
            self.viewer.selected_node = parent;
            self.clampSelection(loaded.document.files.len);
        }
    }

    fn scrollDiff(self: *App, delta: i2) void {
        if (delta < 0) {
            self.viewer.diff_scroll -|= 1;
        } else {
            self.viewer.diff_scroll += 1;
        }
        self.clampDiffNavigation();
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
            max_scroll = @max(max_scroll, maxHorizontalScrollForBodyRow(body_row, pane_width));
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

    fn selectHunkDelta(self: *App, delta: i2) void {
        const file = self.selectedFile() orelse return;
        if (file.hunks.len == 0) return;

        if (delta < 0) {
            if (self.viewer.selected_hunk > 0) self.viewer.selected_hunk -= 1;
        } else if (self.viewer.selected_hunk + 1 < file.hunks.len) {
            self.viewer.selected_hunk += 1;
        }

        self.scrollSelectedHunkIntoView();
        self.clampDiffNavigation();
    }

    fn toggleSelectedHunkFold(self: *App) void {
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.document.files.len) return;
        const file = loaded.document.files[file_index];
        if (self.viewer.selected_hunk >= file.hunks.len) return;

        if (!loaded.isHunkFolded(file_index, self.viewer.selected_hunk) and
            self.currentSearchMatchInHunkBody(self.viewer.selected_hunk))
        {
            return;
        }

        loaded.toggleHunkFold(file_index, self.viewer.selected_hunk);
        self.updateSearchMatchOffset();
        self.scrollSelectedHunkIntoView();
        self.clampDiffNavigation();
    }

    fn scrollSelectedHunkIntoView(self: *App) void {
        const mode = self.effectiveDisplayMode();
        const target = self.selectedHunkOffset(mode, self.viewer.selected_hunk);
        const visible_rows = self.diffVisibleRows();
        if (target < self.viewer.diff_scroll) {
            self.viewer.diff_scroll = target;
        } else if (visible_rows > 0 and target >= self.viewer.diff_scroll + visible_rows) {
            self.viewer.diff_scroll = target + 1 - visible_rows;
        }
    }

    fn clampDiffNavigation(self: *App) void {
        const file = self.selectedFile() orelse {
            self.resetDiffPosition();
            return;
        };

        if (file.hunks.len == 0) {
            self.viewer.selected_hunk = 0;
        } else if (self.viewer.selected_hunk >= file.hunks.len) {
            self.viewer.selected_hunk = file.hunks.len - 1;
        }

        const mode = self.effectiveDisplayMode();
        const line_count = self.selectedFileLineIndex(mode).lineCount();
        const visible_rows = self.diffVisibleRows();
        const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
        if (self.viewer.diff_scroll > max_scroll) self.viewer.diff_scroll = max_scroll;
    }

    fn clampDiffNavigationKeepingHunkVisible(self: *App) void {
        self.clampDiffNavigation();
        if (self.selectedFile()) |file| {
            if (file.hunks.len > 0) self.scrollSelectedHunkIntoView();
        }
        self.clampDiffNavigation();
    }

    fn resetDiffPosition(self: *App) void {
        self.viewer.diff_scroll = 0;
        self.viewer.selected_hunk = 0;
        self.clearSearchMatch();
    }

    fn enterSearchMode(self: *App) void {
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
        self.file_search.no_match = false;
    }

    fn cancelFileSearchMode(self: *App, allocator: std.mem.Allocator) void {
        self.file_search.mode = false;
        self.file_search.input = .{};
        self.file_search.filter.deinit(allocator);
        self.file_search.no_match = false;
        self.viewer.focus = if (self.viewer.sidebar_hidden) .diff else self.file_search_return_focus;
    }

    fn enterRepoPickerMode(self: *App, allocator: std.mem.Allocator) !void {
        if (self.repo_state.workspaceRepos() == null) return;

        self.repo_picker.mode = true;
        self.repo_picker.input = .{};
        self.repo_picker.no_match = false;
        try self.refreshRepoPickerFilter(allocator);
        self.focusRepoPickerOnActive();
    }

    fn cancelRepoPickerMode(self: *App, allocator: std.mem.Allocator) void {
        self.repo_picker.mode = false;
        self.repo_picker.input = .{};
        self.repo_picker.filter.deinit(allocator);
        self.repo_picker.no_match = false;
    }

    fn submitRepoPicker(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const focused = self.repo_picker.filter.list.focusedIndex();
        const repo_index = self.repo_picker.filter.sourceIndex(focused) orelse {
            self.repo_picker.no_match = true;
            return;
        };
        const repos = self.repo_state.workspaceRepos() orelse return;
        if (repo_index >= repos.len) {
            self.repo_picker.no_match = true;
            return;
        }

        self.cancelRepoPickerMode(ctx.allocator());
        if (repo_index == self.repo_state.active_index) return;

        try self.startDiffLoadWithRepoRoot(ctx, repos[repo_index].canonical_root, true);
        self.repo_state.active_index = repo_index;
        self.viewer.selected_file = 0;
        self.viewer.selected_node = 0;
        self.clearSearch();
    }

    fn refreshRepoPickerFilter(self: *App, allocator: std.mem.Allocator) !void {
        const repos = self.repo_state.workspaceRepos() orelse return;

        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(allocator);

        for (repos) |repo| {
            try labels.append(allocator, repo.display_path);
        }

        // ListFilter owns the filtered index arrays; repository labels remain
        // borrowed from the current discovery result.
        try self.repo_picker.filter.apply(allocator, labels.items, self.repo_picker.input.slice());
    }

    fn focusRepoPickerOnActive(self: *App) void {
        var visible_index: usize = 0;
        while (visible_index < self.repo_picker.filter.labels.len) : (visible_index += 1) {
            const source_index = self.repo_picker.filter.sourceIndex(visible_index) orelse continue;
            if (source_index != self.repo_state.active_index) continue;
            while (self.repo_picker.filter.list.focusedIndex() < visible_index) {
                self.repo_picker.filter.update(.move_next);
            }
            return;
        }
    }

    fn toggleReviewedFile(self: *App, allocator: std.mem.Allocator) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.viewer.selected_node >= loaded.tree.nodes.len) return;

        const node = loaded.tree.nodes[self.viewer.selected_node];
        const file_index = node.file_index orelse return;
        if (file_index >= loaded.reviewed_files.len) return;
        const reviewed = !loaded.reviewed_files[file_index];
        try self.reviewed_store.set(allocator, self.activeRepoRoot(), loaded.document.files[file_index], reviewed);
        loaded.reviewed_files[file_index] = reviewed;
        if (self.hide_reviewed_files) {
            try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, true, self.changed_file_filter);
            self.reconcileSelectionAfterVisibleNodeChange(loaded);
            self.clampDiffNavigation();
        }
    }

    fn toggleHideReviewedFiles(self: *App) !void {
        self.hide_reviewed_files = !self.hide_reviewed_files;
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.hide_reviewed_files, self.changed_file_filter);
        self.reconcileSelectionAfterVisibleNodeChange(loaded);
        self.clampDiffNavigation();
    }

    fn cycleChangedFileFilter(self: *App) !void {
        self.changed_file_filter = self.changed_file_filter.next();
        const loaded = self.activeLoadedDiff() orelse return;
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.hide_reviewed_files, self.changed_file_filter);
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
            self.file_search.filter.deinit(allocator);
            self.file_search.no_match = true;
            return;
        };

        // Go-to-file should land on the file row, not on a still-collapsed
        // parent directory that hides the matched path.
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        const load_allocator = self.loadArenaAllocator() orelse {
            self.file_search.filter.deinit(allocator);
            return;
        };
        loaded.rebuildVisibleNodes(load_allocator, self.hide_reviewed_files, self.changed_file_filter) catch {
            self.file_search.filter.deinit(allocator);
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
        self.search.query = self.search.input;
        self.clearSearchMatch();
        if (self.search.query.len == 0) {
            return;
        }
        self.selectSearchMatch(.forward);
    }

    fn selectSearchMatch(self: *App, direction: diff_search.Direction) void {
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
        self.resetDiffHorizontalScroll();
        if (self.search.match_offset) |offset| self.viewer.diff_scroll = offset;
        self.clampDiffNavigation();
    }

    fn refreshSearchForSelectedFile(self: *App) void {
        self.clearSearchMatch();
        if (self.search.query.len == 0) return;
        const file = self.selectedFile() orelse return;
        const next = diff_search.findMatch(file, self.effectiveDisplayMode(), self.search.query.slice(), null, .forward) orelse return;
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        if (self.search.match_offset) |offset| self.viewer.diff_scroll = offset;
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

    fn selectedFile(self: *const App) ?diff_parser.FileDiff {
        const loaded = self.activeLoadedDiffConst() orelse return null;
        const file_index = self.selectedFileIndex(loaded) orelse return null;
        return loaded.document.files[file_index];
    }

    fn selectedFileLineIndex(self: *const App, mode: diff_render.DisplayMode) diff_view_model.RenderedLineIndex {
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
        const loaded = self.activeLoadedDiffConst() orelse return &.{};
        const file_index = self.selectedFileIndex(loaded) orelse return &.{};
        return loaded.foldedHunksForFile(file_index);
    }

    fn selectedHunkOffset(self: *const App, mode: diff_render.DisplayMode, hunk_index: usize) usize {
        const loaded = self.activeLoadedDiffConst() orelse return 0;
        const file_index = self.selectedFileIndex(loaded) orelse return 0;
        if (loaded.rendered_line_cache.indexFor(file_index, mode)) |index| return index.hunkOffset(hunk_index);
        return diff_view_model.hunkBodyLineOffsetFolded(loaded.document.files[file_index], mode, hunk_index, loaded.foldedHunksForFile(file_index));
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
            self.viewer.selected_file = 0;
            self.viewer.selected_node = 0;
            return;
        }
        if (self.viewer.selected_file >= file_count) self.viewer.selected_file = file_count - 1;
        if (self.activeLoadedDiff()) |loaded| {
            if (self.viewer.selected_node >= loaded.tree.nodes.len) {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            if (loaded.visibleAncestorOrSelf(self.viewer.selected_node)) |visible_node| {
                self.viewer.selected_node = visible_node;
            } else if (loaded.tree.selectedNodeIndex(self.viewer.selected_file)) |file_node| {
                self.viewer.selected_node = file_node;
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

    fn selectedFileIndex(self: *const App, loaded: *const LoadedDiff) ?usize {
        if (loaded.document.files.len == 0) return null;
        return @min(self.viewer.selected_file, loaded.document.files.len - 1);
    }

    fn syncSidebarNodeToSelectedFile(self: *App, loaded: *const LoadedDiff) void {
        const file_index = self.selectedFileIndex(loaded) orelse {
            self.viewer.selected_node = 0;
            return;
        };
        self.viewer.selected_node = loaded.tree.selectedNodeIndex(file_index) orelse 0;
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
            if (!loaded.shouldIncludeFileNode(index, self.hide_reviewed_files, self.changed_file_filter)) continue;
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
            .loaded => |*loaded| loaded,
            else => null,
        };
    }

    fn activeLoadedDiffConst(self: *const App) ?*const LoadedDiff {
        return switch (self.load.state) {
            .loaded => |*loaded| loaded,
            else => null,
        };
    }

    fn loadArenaAllocator(self: *App) ?std.mem.Allocator {
        if (self.load.arena) |*arena| return arena.allocator();
        return null;
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

fn maxHorizontalScrollForBodyRow(body_row: diff_view_model.BodyRow, pane_width: u16) usize {
    return switch (body_row) {
        .unified_line => |line| maxHorizontalScrollForText(line.text, if (pane_width > 12) pane_width - 12 else 0),
        .side_by_side => |side_row| maxHorizontalScrollForSideBySideRow(side_row, pane_width),
        else => 0,
    };
}

fn maxHorizontalScrollForSideBySideRow(side_row: diff_view_model.SideBySideRow, pane_width: u16) usize {
    const gutter_col = pane_width / 2;
    const new_col = gutter_col + 1;
    const old_text_width: u16 = if (gutter_col > 7) gutter_col - 7 else 0;
    const new_width: u16 = if (pane_width > new_col) pane_width - new_col else 0;
    const new_text_width: u16 = if (new_width > 7) new_width - 7 else 0;
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

fn maxHorizontalScrollForText(text: []const u8, visible_width: u16) usize {
    const width = chasen.text.displayWidth(text);
    if (width <= visible_width) return 0;
    return width - visible_width;
}

const SearchQuery = struct {
    buffer: [128]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const SearchQuery) []const u8 {
        return self.buffer[0..self.len];
    }

    fn insert(self: *SearchQuery, codepoint: u21) !void {
        var bytes: [4]u8 = undefined;
        const written = try std.unicode.utf8Encode(codepoint, &bytes);
        if (self.len + written > self.buffer.len) return;
        @memcpy(self.buffer[self.len .. self.len + written], bytes[0..written]);
        self.len += written;
    }

    fn backspace(self: *SearchQuery) void {
        if (self.len == 0) return;
        var view = std.unicode.Utf8View.initUnchecked(self.slice());
        var iterator = view.iterator();
        var previous_end: usize = 0;
        while (iterator.nextCodepointSlice()) |bytes| {
            const end = @intFromPtr(bytes.ptr) - @intFromPtr(self.buffer[0..].ptr) + bytes.len;
            if (end >= self.len) break;
            previous_end = end;
        }
        self.len = previous_end;
    }
};

const LoadState = union(enum) {
    idle,
    loading,
    empty: EmptyReason,
    loaded: LoadedDiff,
    failed: []const u8,
};

const EmptyReason = enum {
    no_changes,
    no_repository,
};

fn parentDirectoryNodeIndex(tree: file_tree.FileTree, node_index: usize) ?usize {
    if (node_index >= tree.nodes.len) return null;
    const node = tree.nodes[node_index];
    var index = node_index;
    while (index > 0) {
        index -= 1;
        const candidate = tree.nodes[index];
        if (candidate.kind != .directory) continue;
        if (candidate.depth >= node.depth) continue;
        if (node.path.len > candidate.path.len and
            std.mem.startsWith(u8, node.path, candidate.path) and
            node.path[candidate.path.len] == '/')
        {
            return index;
        }
    }
    return null;
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{
            .diff_scroll = 4,
            .selected_hunk = 1,
        },
    };

    app.selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 4), app.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_hunk);

    app.selectFileAbsolute(0);
    try std.testing.expectEqual(@as(usize, 4), app.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_hunk);
}

test "mode toggle keeps selected hunk visible" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{
            .display_mode = .unified,
            .selected_hunk = 1,
        },
    };

    app.scrollSelectedHunkIntoView();
    try std.testing.expect(app.viewer.diff_scroll > 0);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();

    const file = testFileWithHunks();
    const target = diff_render.hunkBodyLineOffset(file, app.effectiveDisplayMode(), app.viewer.selected_hunk);
    const visible_rows = app.diffVisibleRows();
    try std.testing.expect(target >= app.viewer.diff_scroll);
    try std.testing.expect(visible_rows == 0 or target < app.viewer.diff_scroll + visible_rows);
}

test "sidebar visibility toggle uses full diff width and keeps selection" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 8 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffWide() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffWide() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffWide() } },
        .viewer = .{
            .display_mode = .side_by_side,
            .sidebar_hidden = true,
        },
    };

    setSearchQuery(&app, "wide");
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
        maxHorizontalScrollForBodyRow(.{ .side_by_side = .{ .single = line } }, 80),
    );
}

test "display mode and search navigation reset horizontal scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 120, .height = 8 },
        .load = .{ .state = .{ .loaded = testLoadedDiffWide() } },
        .viewer = .{
            .display_mode = .unified,
            .diff_horizontal_scroll = 16,
        },
    };

    try app.update(.toggle_display_mode, undefined);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);

    app.viewer.diff_horizontal_scroll = 16;
    setSearchQuery(&app, "wide");
    app.submitSearch();
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_horizontal_scroll);
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

test "mouse click focuses sidebar and diff panes" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 20 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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

test "mouse wheel scrolls the pane under the pointer" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load = .{ .state = .{ .loaded = testLoadedDiffTwo() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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

test "mouse horizontal wheel scrolls diff pane horizontally" {
    var app: App = .{
        .terminal_size = .{ .width = 80, .height = 12 },
        .load = .{ .state = .{ .loaded = testLoadedDiffWide() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
    };

    const content = app_view.shellContentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(testMouseEventTyped(content.col + 1, content.row + 1, .left, .release)) == null);
    try std.testing.expect(app.handleEvent(testMouseEventTyped(content.col + 1, content.row + 1, .left, .motion)) == null);
}

test "mode change resyncs search match to rendered body offsets" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 14 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .display_mode = .unified },
    };
    setSearchQuery(&app, "late new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 12), app.search.match_offset);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 10), app.search.match_offset);
    try std.testing.expect(app.search.match_offset.? >= app.viewer.diff_scroll);
    try std.testing.expect(app.search.match_offset.? < app.viewer.diff_scroll + app.diffVisibleRows());
}

test "mode change keeps search near later matches" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .display_mode = .unified },
    };
    setSearchQuery(&app, "new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
    app.selectSearchMatch(.forward);
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 12), app.search.match_offset);

    app.viewer.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 10), app.search.match_offset);
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
        .load = .{ .arena = arena, .state = .{ .loaded = loaded } },
        .viewer = .{ .selected_hunk = 0 },
    };
    defer app.clearLoadedDiff();

    try std.testing.expectEqual(@as(usize, 13), app.selectedFileLineIndex(.unified).lineCount());
    app.toggleSelectedHunkFold();

    const active = app.loadedDiff().?;
    try std.testing.expect(active.isHunkFolded(0, 0));
    try std.testing.expectEqual(@as(usize, 8), app.selectedFileLineIndex(.unified).lineCount());
    try std.testing.expectEqual(@as(usize, 1), active.renderedLineIndex(0, .unified).hunkLineCount(0));
    try std.testing.expectEqual(@as(usize, 7), app.selectedFileLineIndex(.side_by_side).lineCount());
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
        .load = .{ .arena = arena, .state = .{ .loaded = loaded } },
    };
    defer app.clearLoadedDiff();
    setSearchQuery(&app, "new");

    app.submitSearch();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
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
        .load = .{ .arena = arena, .state = .{ .loaded = loaded } },
    };
    defer app.clearLoadedDiff();
    setSearchQuery(&app, "new");
    app.submitSearch();

    app.toggleSelectedHunkFold();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
}

test "file change resyncs retained search query to selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = .{ .state = .{ .loaded = testLoadedDiffTwo() } },
        .viewer = .{ .display_mode = .unified },
    };
    setSearchQuery(&app, "target");

    app.selectFileAbsolute(1);

    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
    try expectSearchCoordinate(&app, .{ .metadata = 0 });
    try std.testing.expectEqual(@as(?usize, 0), app.search.match_offset);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.diff_scroll);
}

test "sidebar navigation can select directories without changing selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = .{ .state = .{ .loaded = testLoadedDiffNested() } },
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

test "toggling selected directory collapses visible descendants" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load = .{ .arena = .init(std.testing.allocator), .state = .{ .loaded = testLoadedDiffNested() } },
        .viewer = .{
            .selected_file = 0,
            .selected_node = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleSelectedDirectory();

    const loaded = app.load.state.loaded;
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
        .load = .{ .arena = .init(std.testing.allocator), .state = .{ .loaded = testLoadedDiffNested() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffNested() } },
        .file_search = .{ .mode = true },
    };
    setFileSearchInput(&app, "missing");

    defer app.file_search.filter.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search.mode);
    try std.testing.expect(app.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
}

test "file search skips hidden reviewed matches" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load = .{
            .arena = .init(std.testing.allocator),
            .state = .{ .loaded = .{
                .text = "",
                .document = .{ .files = &test_files_two },
                .tree = .{ .nodes = &test_tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            } },
        },
        .file_search = .{ .mode = true },
        .hide_reviewed_files = true,
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
        .load = .{ .state = .{ .loaded = testLoadedDiffNested() } },
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
        .load = .{ .arena = .init(std.testing.allocator), .state = .{ .loaded = testLoadedDiffNested() } },
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
        .load = .{ .state = .{ .loaded = testLoadedDiffTwoWithStatuses() } },
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded);

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
            .file_index = 0,
            .status = .modified,
            .mode_changed = true,
        },
    };
    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = .{ .state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_one },
            .tree = .{ .nodes = &nodes },
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } } },
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(2, sidebar_header_rows, "M");
    try ts.expectCellText(4, sidebar_header_rows, "m");
}

test "sidebar title indicates active focus" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .focus = .sidebar },
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(0, 0, "▸");
    try std.testing.expect(ts.surface.readCell(0, 0).?.style.reverse);
}

test "diff status row indicates active focus" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .focus = .diff },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(0, 2, "▸");
    try std.testing.expect(ts.surface.readCell(0, 2).?.style.reverse);
}

test "diff search row keeps active focus style" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .focus = .diff },
    };
    setSearchQuery(&app, "missing");

    try app.viewDiffPane(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(0, 2, "s");
    try std.testing.expect(ts.surface.readCell(0, 2).?.style.reverse);
}

test "changed file filter keeps only matching status rows" {
    var app: App = .{
        .load = .{ .arena = .init(std.testing.allocator), .state = .{ .loaded = testLoadedDiffTwoWithStatuses() } },
        .changed_file_filter = .added,
        .viewer = .{
            .selected_node = 1,
            .selected_file = 1,
        },
    };
    defer app.clearLoadedDiff();

    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, false, app.changed_file_filter);

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
}

test "finishDiffLoad applies active changed file filter" {
    var app: App = .{
        .load = .{ .generation = 1 },
        .changed_file_filter = .added,
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
        .load = .{ .arena = .init(std.testing.allocator), .state = .{ .loaded = testLoadedDiffTwoWithStatuses() } },
        .viewer = .{
            .selected_node = 1,
            .selected_file = 1,
        },
    };
    defer app.clearLoadedDiff();

    try app.cycleChangedFileFilter();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "file search skips files outside active changed filter" {
    var app: App = .{
        .load = .{ .state = .{ .loaded = testLoadedDiffTwoWithStatuses() } },
        .file_search = .{ .mode = true },
        .changed_file_filter = .added,
    };
    setFileSearchInput(&app, "deleted");
    defer app.file_search.filter.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search.mode);
    try std.testing.expect(app.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), app.viewer.selected_file);
}

test "toggleReviewedFile marks only selected file nodes" {
    var reviewed = [_]bool{ false, false };
    var app: App = .{
        .load = .{ .state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } } },
        .viewer = .{
            .selected_node = 0,
            .selected_file = 0,
        },
    };
    defer app.reviewed_store.deinit(std.testing.allocator);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);

    app.viewer.selected_node = 1;
    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);
}

test "reviewed state survives active loaded diff replacement" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .load = .{ .state = .{ .loaded = testLoadedDiffTwo() } },
        .viewer = .{
            .selected_node = 0,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);

    var loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.load.active_reviewed_files_owned = true;

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);

    app.clearLoadedDiff();
    app.load.state = .{ .loaded = testLoadedDiffTwo() };
    loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.load.active_reviewed_files_owned = true;

    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);
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
    defer app.repo_picker.filter.deinit(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.filter.labels.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.filter.list.focusedIndex());
}

test "sidebar renders reviewed marker" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    var reviewed = [_]bool{ true, false };
    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load = .{ .state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two_statuses },
            .tree = .{ .nodes = &test_tree_two_status_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } } },
    };

    try app.viewSidebar(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(1, sidebar_header_rows, "✓");
    try ts.expectCellText(4, sidebar_header_rows, "A");
}

test "hide reviewed files removes reviewed file rows from visible list" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load = .{
            .arena = .init(std.testing.allocator),
            .state = .{ .loaded = .{
                .text = "",
                .document = .{ .files = &test_files_two },
                .tree = .{ .nodes = &test_tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            } },
        },
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expect(app.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.viewer.selected_file);
}

test "hide reviewed files removes directories with no visible file descendants" {
    var reviewed = [_]bool{ true, true };
    var app: App = .{
        .load = .{
            .arena = .init(std.testing.allocator),
            .state = .{ .loaded = .{
                .text = "",
                .document = .{ .files = &test_files_two },
                .tree = .{ .nodes = &test_tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            } },
        },
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
        .load = .{
            .arena = .init(std.testing.allocator),
            .state = .{ .loaded = .{
                .text = "",
                .document = .{ .files = &test_files_two },
                .tree = .{ .nodes = &test_tree_non_contiguous_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            } },
        },
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
        .load = .{
            .arena = .init(std.testing.allocator),
            .state = .{ .loaded = .{
                .text = "",
                .document = .{ .files = &test_files_two },
                .tree = .{ .nodes = &test_tree_nested_nodes },
                .reviewed_files = &reviewed,
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            } },
        },
        .viewer = .{
            .selected_node = 1,
            .selected_file = 0,
        },
        .hide_reviewed_files = true,
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
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .search = .{ .match_offset = 4 },
        .viewer = .{ .diff_scroll = 3 },
    };

    app.drawSearchMatchMarker(&ts.surface);

    try ts.expectCellText(0, diff_body_start_row + 1, ">");
}

test "search marker gutter does not overwrite diff content" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .search = .{ .match_offset = 0 },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(0, diff_body_start_row, ">");
    try ts.expectCellText(1, diff_body_start_row, "i");
}

test "status mode label uses diff content width after marker gutter" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(72, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 72, .height = 9 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .viewer = .{ .display_mode = .side_by_side },
    };

    try app.viewDiffPane(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(19, 2, "u");
    try ts.expectCellText(20, 2, "n");
    try ts.expectCellText(21, 2, "i");
}

test "search input header does not show no match before submit" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .search = .{ .mode = true },
    };
    setSearchInput(&app, "missing");

    try app.viewDiffPane(&ts.surface, app.load.state.loaded);

    try ts.expectCellText(0, 2, "s");
    try ts.expectCellText(8, 2, "m");
    try ts.expectCellText(15, 2, " ");
}

test "canceling edited search restores committed query and match" {
    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load = .{ .state = .{ .loaded = testLoadedDiffOne() } },
        .search = .{
            .match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
            .match_offset = 7,
        },
    };
    setSearchQuery(&app, "new");

    app.enterSearchMode();
    app.search.input.backspace();
    try app.search.input.insert('x');
    app.cancelSearchMode();

    try std.testing.expectEqualStrings("new", app.search.query.slice());
    try std.testing.expectEqualStrings("new", app.search.input.slice());
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search.match_offset);
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

    const app: App = .{
        .terminal_size = .{ .width = 90, .height = 18 },
        .load = .{ .state = .{ .failed = "git diff failed\nsecond line" } },
    };

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
        .load = .{ .arena = arena, .state = .{ .loaded = loaded } },
        .changed_file_filter = .binary,
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

    try std.testing.expect(app.load.arena != null);
    try std.testing.expect(app.load.state == .loaded);
    try std.testing.expectEqual(@as(usize, 1), app.load.state.loaded.document.files.len);
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: App = .{ .load = .{ .generation = 2 } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, test_diff_one);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.load.arena == null);
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

    try std.testing.expect(app.load.arena != null);
    try std.testing.expectEqualStrings("failed", app.load.state.failed);
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

fn setSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.search.query.buffer[0..query.len], query);
    app.search.query.len = query.len;
    setSearchInput(app, query);
}

fn setSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.search.input.buffer[0..query.len], query);
    app.search.input.len = query.len;
}

fn setFileSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.file_search.input.buffer[0..query.len], query);
    app.file_search.input.len = query.len;
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

const test_tree_one_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .file_index = 0 },
};

const test_tree_two_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .file_index = 0 },
    .{ .kind = .file, .name = "b", .path = "b", .depth = 0, .file_index = 1 },
};

const test_tree_nested_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .file_index = 0 },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .file_index = 1 },
};

const test_tree_non_contiguous_nodes = [_]file_tree.Node{
    .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
    .{ .kind = .file, .name = "a", .path = "src/a", .depth = 1, .file_index = 0 },
    .{ .kind = .directory, .name = "lib", .path = "lib", .depth = 0 },
    .{ .kind = .file, .name = "c", .path = "lib/c", .depth = 1, .file_index = 0 },
    .{ .kind = .file, .name = "b", .path = "src/b", .depth = 1, .file_index = 1 },
};

const test_tree_two_status_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "added.zig", .path = "src/added.zig", .depth = 1, .file_index = 0, .status = .added },
    .{ .kind = .file, .name = "deleted.zig", .path = "src/deleted.zig", .depth = 1, .file_index = 1, .status = .deleted },
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
