const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
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
const review_state = @import("review_state.zig");
const sidebar_view_model = @import("sidebar_view_model.zig");

const auto_reload_timer_id = "gitframe.auto_reload";
const auto_reload_interval_ns = 2 * std.time.ns_per_s;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const LoadedDiff = loaded_diff.LoadedDiff;

pub const App = struct {
    config: CliConfig = .{},
    env_map: ?*std.process.Environ.Map = null,
    allocator: ?std.mem.Allocator = null,
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    load_state: LoadState = .idle,
    status_message_buf: [160]u8 = undefined,
    status_message: []const u8 = "",
    /// Sticky file shown in the diff pane. Directory sidebar rows can be
    /// selected without changing this value.
    selected_file: usize = 0,
    /// Sidebar cursor. This may point at either a directory node or a file node.
    selected_node: usize = 0,
    focus: Focus = .sidebar,
    diff_scroll: usize = 0,
    selected_hunk: usize = 0,
    display_mode: diff_render.DisplayMode = .side_by_side,
    search_mode: bool = false,
    search_input: SearchQuery = .{},
    search_query: SearchQuery = .{},
    search_match: ?diff_search.Match = null,
    search_match_offset: ?usize = null,
    file_search_mode: bool = false,
    file_search_input: SearchQuery = .{},
    file_search_filter: ui.ListFilter = .{},
    file_search_no_match: bool = false,
    file_search_return_focus: Focus = .sidebar,
    repo_picker_mode: bool = false,
    repo_picker_input: SearchQuery = .{},
    repo_picker_filter: ui.ListFilter = .{},
    repo_picker_no_match: bool = false,
    hide_reviewed_files: bool = false,
    changed_file_filter: ChangedFileFilter = .all,
    repo_discovery_result: ?repo_discovery.DiscoveryResult = null,
    active_repo: usize = 0,
    load_in_flight: bool = false,
    load_in_flight_generation: ?u64 = null,
    /// Session-level source of truth for reviewed files. The active LoadedDiff
    /// keeps a materialized bool slice so hide-reviewed hot paths stay O(1).
    reviewed_store: review_state.Store = .{},
    active_reviewed_files_owned: bool = false,
    /// Owns the currently loaded raw diff, parsed document arrays, and error
    /// messages. Recreated on every successful load/reload.
    load_arena: ?std.heap.ArenaAllocator = null,
    /// Monotonic id used to ignore stale async task results after reload.
    load_generation: u64 = 0,

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
        page_diff_up,
        page_diff_down,
        select_previous_hunk,
        select_next_hunk,
        toggle_hunk_fold,
        select_first_file,
        select_last_file,
        toggle_focus,
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
        self.clearRepoDiscovery(deinit_ctx.allocator);
        self.file_search_filter.deinit(deinit_ctx.allocator);
        self.repo_picker_filter.deinit(deinit_ctx.allocator);
        self.reviewed_store.deinit(deinit_ctx.allocator);
    }

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .terminal_resized => |size| {
                self.terminal_size = size;
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
            .page_diff_up => self.pageDiff(-1),
            .page_diff_down => self.pageDiff(1),
            .select_previous_hunk => self.selectHunkDelta(-1),
            .select_next_hunk => self.selectHunkDelta(1),
            .toggle_hunk_fold => self.toggleSelectedHunkFold(),
            .select_first_file => self.selectFileAbsolute(0),
            .select_last_file => self.selectLastFile(),
            .toggle_focus => self.focus = self.focus.toggled(),
            .toggle_display_mode => {
                self.display_mode = self.display_mode.toggled();
                self.clampDiffNavigationKeepingHunkVisible();
                self.updateSearchMatchOffset();
                self.scrollSearchMatchIntoView();
                self.clampDiffNavigation();
            },
            .enter_search => self.enterSearchMode(),
            .cancel_search => self.cancelSearchMode(),
            .clear_search => self.clearSearch(),
            .submit_search => self.submitSearch(),
            .search_insert => |codepoint| self.search_input.insert(codepoint) catch {},
            .search_backspace => self.search_input.backspace(),
            .select_next_search_match => self.selectSearchMatch(.forward),
            .select_previous_search_match => self.selectSearchMatch(.backward),
            .enter_file_search => self.enterFileSearchMode(),
            .cancel_file_search => self.cancelFileSearchMode(ctx.allocator()),
            .submit_file_search => try self.submitFileSearch(ctx.allocator()),
            .file_search_insert => |codepoint| {
                self.file_search_no_match = false;
                self.file_search_input.insert(codepoint) catch {};
            },
            .file_search_backspace => {
                self.file_search_no_match = false;
                self.file_search_input.backspace();
            },
            .enter_repo_picker => try self.enterRepoPickerMode(ctx.allocator()),
            .cancel_repo_picker => self.cancelRepoPickerMode(ctx.allocator()),
            .submit_repo_picker => try self.submitRepoPicker(ctx),
            .repo_picker_insert => |codepoint| {
                self.repo_picker_no_match = false;
                self.repo_picker_input.insert(codepoint) catch {};
                try self.refreshRepoPickerFilter(ctx.allocator());
            },
            .repo_picker_backspace => {
                self.repo_picker_no_match = false;
                self.repo_picker_input.backspace();
                try self.refreshRepoPickerFilter(ctx.allocator());
            },
            .repo_picker_move_previous => self.repo_picker_filter.update(.move_prev),
            .repo_picker_move_next => self.repo_picker_filter.update(.move_next),
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
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        surface.hideCursor();

        const footer_row = size.height - footer_rows;
        var body = surface.child(.{
            .col = 0,
            .row = 0,
            .width = size.width,
            .height = footer_row,
        });
        try self.viewBody(&body);

        var footer = surface.child(.{
            .col = 0,
            .row = footer_row,
            .width = size.width,
            .height = footer_rows,
        });
        self.viewFooter(&footer);

        if (self.repo_picker_mode) {
            try self.viewRepoPicker(surface);
        }
    }

    pub fn handleEvent(self: *const App, event: chasen.Event) ?Msg {
        return switch (event) {
            .key_press => |key| self.handleKey(key),
            .winsize => |winsize| .{ .terminal_resized = .{
                .width = winsize.cols,
                .height = winsize.rows,
            } },
            else => null,
        };
    }

    fn handleKey(self: *const App, key: chasen.Key) ?Msg {
        if (self.search_mode) {
            if (key.matches(chasen.Key.escape, .{})) return .cancel_search;
            if (key.matches(chasen.Key.enter, .{})) return .submit_search;
            if (key.matches(chasen.Key.backspace, .{})) return .search_backspace;
            if (isSearchCodepoint(key.codepoint)) return .{ .search_insert = key.codepoint };
            return null;
        }

        if (self.file_search_mode) {
            if (key.matches(chasen.Key.escape, .{})) return .cancel_file_search;
            if (key.matches(chasen.Key.enter, .{})) return .submit_file_search;
            if (key.matches(chasen.Key.backspace, .{})) return .file_search_backspace;
            if (isSearchCodepoint(key.codepoint)) return .{ .file_search_insert = key.codepoint };
            return null;
        }

        if (self.repo_picker_mode) {
            if (key.matches(chasen.Key.escape, .{})) return .cancel_repo_picker;
            if (key.matches(chasen.Key.enter, .{})) return .submit_repo_picker;
            if (key.matches(chasen.Key.backspace, .{})) return .repo_picker_backspace;
            return switch (key.codepoint) {
                'k', chasen.Key.up => .repo_picker_move_previous,
                'j', chasen.Key.down => .repo_picker_move_next,
                'q' => .cancel_repo_picker,
                else => if (isSearchCodepoint(key.codepoint)) .{ .repo_picker_insert = key.codepoint } else null,
            };
        }

        if (key.matches(chasen.Key.tab, .{})) return .toggle_focus;
        if (key.matches(chasen.Key.page_up, .{})) return .page_diff_up;
        if (key.matches(chasen.Key.page_down, .{})) return .page_diff_down;
        if (key.matches(chasen.Key.home, .{})) return .select_first_file;
        if (key.matches(chasen.Key.end, .{})) return .select_last_file;
        if (key.matches(chasen.Key.escape, .{}) and self.search_query.len > 0) return .clear_search;
        if (self.focus == .sidebar and key.matches(chasen.Key.enter, .{})) return .toggle_directory;
        if (self.focus == .diff and key.matches(chasen.Key.enter, .{})) return .toggle_hunk_fold;
        if (self.focus == .sidebar and key.matches(chasen.Key.right, .{})) return .expand_directory;
        if (self.focus == .sidebar and key.matches(chasen.Key.left, .{})) return .collapse_or_parent_directory;

        return switch (key.codepoint) {
            'k', chasen.Key.up => if (self.focus == .diff) .scroll_diff_up else .select_previous_file,
            'j', chasen.Key.down => if (self.focus == .diff) .scroll_diff_down else .select_next_file,
            '/' => .enter_search,
            'n' => if (self.search_query.len > 0) .select_next_search_match else .select_next_hunk,
            'N' => if (self.search_query.len > 0) .select_previous_search_match else null,
            'p' => if (self.search_query.len > 0) .select_previous_search_match else .select_previous_hunk,
            'g' => .select_first_file,
            'G' => .select_last_file,
            'f' => .enter_file_search,
            'R' => .enter_repo_picker,
            'F' => .cycle_changed_file_filter,
            'v' => .toggle_reviewed_file,
            'H' => .toggle_hide_reviewed_files,
            'e' => .open_selected_file_in_editor,
            'u' => .toggle_display_mode,
            'q' => .quit,
            'r' => .reload,
            else => null,
        };
    }

    fn viewBody(self: *const App, surface: *chasen.Surface) !void {
        switch (self.load_state) {
            .loaded => |loaded| return self.viewLoadedDiff(surface, loaded),
            else => {},
        }

        const size = surface.size();
        const title = "GitFrame";
        const subtitle = "Read-only diff viewer shell";

        var panel = surface.child(.{
            .col = if (size.width > 60) (size.width - 60) / 2 else 0,
            .row = if (size.height > 10) (size.height - 10) / 2 else 0,
            .width = @min(size.width, 60),
            .height = if (size.height > 10) 10 else size.height,
        });
        var col = panel.column(.{ .gap = 1 });
        col.borrowText(title, .{ .bold = true, .fg = .{ .index = 14 } });
        col.borrowText(subtitle, .{ .fg = .gray });
        try col.print("Source: {s}", .{self.config.sourceLabel()});
        try self.viewLoadState(&col);
        col.borrowText("Keys: r reload, q quit", .{ .fg = .gray });
    }

    fn viewLoadedDiff(self: *const App, surface: *chasen.Surface, loaded: LoadedDiff) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        const sidebar_width = sidebarWidth(size.width);
        var sidebar = surface.child(.{
            .col = 0,
            .row = 0,
            .width = sidebar_width,
            .height = size.height,
        });
        try self.viewSidebar(&sidebar, loaded);

        if (size.width > sidebar_width) {
            var row: u16 = 0;
            while (row < size.height) : (row += 1) {
                _ = surface.borrowTextAt(sidebar_width, row, "│", .{ .fg = .gray });
            }
        }

        if (size.width <= sidebar_width + 1) return;
        var diff_pane = surface.child(.{
            .col = sidebar_width + 1,
            .row = 0,
            .width = size.width - sidebar_width - 1,
            .height = size.height,
        });
        try self.viewDiffPane(&diff_pane, loaded);
    }

    fn viewSidebar(self: *const App, surface: *chasen.Surface, loaded: LoadedDiff) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        const title_style: chasen.TextStyle = if (self.focus == .sidebar)
            .{ .bold = true, .reverse = true, .fg = .{ .index = 14 } }
        else
            .{ .bold = true, .fg = .{ .index = 14 } };
        _ = surface.borrowTextAt(0, 0, "Files", title_style);
        _ = try surface.printAt(0, 1, .{ .fg = .gray }, "{d} files / {d} hunks", .{
            loaded.document.files.len,
            loaded.document.totalHunks(),
        });
        if (size.width > 2) {
            if (self.hide_reviewed_files and self.changed_file_filter != .all) {
                _ = try surface.printAt(0, 2, .{ .fg = .{ .index = 11 } }, "hiding reviewed / {s}", .{self.changed_file_filter.label()});
            } else if (self.hide_reviewed_files) {
                _ = surface.borrowTextAt(0, 2, "hiding reviewed", .{ .fg = .{ .index = 11 } });
            } else if (self.changed_file_filter != .all) {
                _ = surface.borrowTextAt(0, 2, self.changed_file_filter.label(), .{ .fg = .{ .index = 11 } });
            }
        }

        if (size.height <= sidebar_header_rows) return;

        const visible_rows: usize = size.height - sidebar_header_rows;
        const visible_count = loaded.visibleNodeCount();
        const selected_row = loaded.visibleRowOfNode(self.selected_node) orelse 0;
        // Sidebar has no independent scroll state; derive the visible window
        // from the selected row each frame.
        const range = ui.ListViewport.visibleRange(visible_count, selected_row, visible_rows);
        var row: u16 = sidebar_header_rows;
        var visible_index: usize = range.start;
        while (visible_index < range.end) : ({
            visible_index += 1;
            row += 1;
        }) {
            const row_model = loaded.sidebarRowAt(visible_index, self.selected_node) orelse continue;
            try drawSidebarRow(surface, row, row_model);
        }
    }

    fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row) !void {
        const width = surface.size().width;
        const row_layout = sidebar_view_model.layout(row_model, width);
        const style = sidebarRowStyle(row_model);
        const marker = if (row_model.selected) ">" else " ";

        if (width > row_layout.marker_col) {
            _ = surface.borrowTextAt(0, row, marker, style);
        }

        if (row_layout.fold_col) |fold_col| {
            if (width > fold_col) {
                const fold_marker = switch (row_model.fold) {
                    .none => "",
                    .expanded => "▾",
                    .collapsed => "▸",
                };
                _ = surface.borrowTextAt(fold_col, row, fold_marker, style);
            }
        }

        if (row_model.status) |status| {
            if (row_layout.badge_col) |badge_col| {
                if (width > badge_col) {
                    _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(status, row_model.selected));
                }
            }
        }

        if (row_layout.mode_col) |mode_col| {
            if (width > mode_col) {
                _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(row_model.selected));
            }
        }

        if (row_layout.reviewed_col) |reviewed_col| {
            if (width > reviewed_col) {
                _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(row_model.selected));
            }
        }

        if (row_layout.name_width > 0) {
            var path_area = surface.child(.{
                .col = row_layout.name_col,
                .row = row,
                .width = row_layout.name_width,
                .height = 1,
            });
            _ = try path_area.copyTextAt(0, 0, row_model.name, style);
        }

        if (row_layout.stats_col) |stats_col| {
            _ = try surface.printAt(stats_col, row, style, "+{d} -{d}", .{
                row_model.stats.added,
                row_model.stats.removed,
            });
        }
    }

    fn sidebarRowStyle(row: sidebar_view_model.Row) chasen.TextStyle {
        if (row.selected) return .{ .reverse = true, .bold = true };
        if (row.kind == .directory) return .{ .bold = true, .fg = .gray };
        return .{};
    }

    fn viewDiffPane(self: *const App, surface: *chasen.Surface, loaded: LoadedDiff) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        if (loaded.document.files.len == 0) {
            _ = surface.borrowTextAt(0, 0, "No parsed files.", .{ .fg = .gray });
            return;
        }

        const selected = @min(self.selected_file, loaded.document.files.len - 1);
        const file = loaded.document.files[selected];
        var diff_content = diffContentSurface(surface);
        const mode = diff_render.effectiveMode(diff_content.size().width, self.display_mode);
        const focus_label = if (self.focus == .diff) "diff" else "sidebar";
        _ = try surface.printAt(0, 2, .{ .fg = .gray }, "{d}/{d}  {d} hunks  {s}  focus:{s}  scroll:{d}", .{
            selected + 1,
            loaded.document.files.len,
            file.hunks.len,
            mode.label(),
            focus_label,
            self.diff_scroll,
        });
        if (self.search_query.len > 0 or self.search_mode) {
            surface.clear(.{ .col = 0, .row = 2, .width = size.width, .height = 1 });
        }
        if (!self.search_mode and self.search_query.len > 0 and size.width > 0) {
            const match_text = if (self.search_match_offset) |offset|
                std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ self.search_query.slice(), offset + 1 }) catch "search"
            else
                std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{self.search_query.slice()}) catch "search";
            _ = surface.copyTextAt(0, 2, match_text, .{ .fg = .{ .index = 11 } }) catch {};
        } else if (self.search_mode and size.width > 0) {
            const prompt_text = std.fmt.allocPrint(surface.frameAllocator(), "search: {s}", .{self.search_input.slice()}) catch "search";
            _ = surface.copyTextAt(0, 2, prompt_text, .{ .fg = .{ .index = 11 } }) catch {};
        }
        try diff_render.renderFile(&diff_content, file, .{
            .requested_mode = self.display_mode,
            .scroll = self.diff_scroll,
            .highlighted_hunk = if (file.hunks.len > 0) self.selected_hunk else null,
            .line_index = loaded.cachedRenderedLineIndex(selected, mode),
            .folded_hunks = loaded.foldedHunksForFile(selected),
        });
        self.drawSearchMatchMarker(surface);
    }

    fn viewLoadState(self: *const App, col: *chasen.Column) !void {
        switch (self.load_state) {
            .idle => col.borrowText("Waiting to load diff.", .{ .fg = .gray }),
            .loading => col.borrowText("Loading diff...", .{ .fg = .{ .index = 11 } }),
            .empty => |reason| switch (reason) {
                .no_changes => col.borrowText("No changes found.", .{ .fg = .gray }),
                .no_repository => {
                    col.borrowText("No Git repositories found.", .{ .fg = .gray });
                    col.borrowText("Run inside a repository or a workspace containing direct child repositories.", .{ .fg = .gray });
                },
            },
            .loaded => |loaded| {
                try col.print("Loaded {d} files / {d} hunks.", .{ loaded.document.files.len, loaded.document.totalHunks() });
                try col.print("{d} bytes across {d} lines.", .{ loaded.bytes, loaded.lines });
            },
            .failed => |message| {
                col.borrowText("Could not load diff:", .{ .fg = .{ .index = 9 }, .bold = true });
                col.borrowText(message, .{ .fg = .{ .index = 9 } });
            },
        }
    }

    fn viewFooter(self: *const App, surface: *chasen.Surface) void {
        const width = surface.size().width;
        if (width == 0) return;

        if (self.search_mode) {
            _ = surface.borrowTextAt(0, 0, "/", .{ .fg = .{ .index = 11 }, .bold = true });
            _ = surface.copyTextAt(1, 0, self.search_input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
            return;
        }

        if (self.file_search_mode) {
            _ = surface.borrowTextAt(0, 0, "file: ", .{ .fg = .{ .index = 11 }, .bold = true });
            _ = surface.copyTextAt(6, 0, self.file_search_input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
            if (self.file_search_no_match) {
                const col: u16 = @intCast(@min(6 + chasen.text.displayWidth(self.file_search_input.slice()) + 1, std.math.maxInt(u16)));
                if (surface.size().width > col) _ = surface.borrowTextAt(col, 0, "(no match)", .{ .fg = .{ .index = 9 } });
            }
            return;
        }

        var col: u16 = 0;
        _ = surface.borrowTextAt(col, 0, "gitframe", .{ .bold = true });
        col +|= 9;
        _ = surface.borrowTextAt(col, 0, "viewer shell", .{ .fg = .gray });
        col +|= 13;
        if (self.config.watch and width > col + 8) {
            _ = surface.borrowTextAt(col, 0, "watch", .{ .fg = .{ .index = 10 } });
            col +|= 7;
        }
        if (self.status_message.len > 0 and width > col + 2) {
            _ = surface.borrowTextAt(col, 0, self.status_message, .{ .fg = .{ .index = 11 } });
            const message_width = chasen.text.displayWidth(self.status_message);
            col +|= @intCast(@min(message_width + 2, std.math.maxInt(u16)));
        }

        const size_text = std.fmt.allocPrint(surface.frameAllocator(), "{d}x{d}", .{
            self.terminal_size.width,
            self.terminal_size.height,
        }) catch return;
        const size_width: u16 = @intCast(@min(chasen.text.displayWidth(size_text), std.math.maxInt(u16)));
        const reserved_size_width: u16 = if (width > size_width + 1) size_width + 1 else 0;
        if (width > col + reserved_size_width) {
            var hint_area = surface.child(.{
                .col = col,
                .row = 0,
                .width = width - col - reserved_size_width,
                .height = 1,
            });
            _ = ui.key_hint.draw(&hint_area, 0, 0, self.footerItems(), .{
                .style = .{ .fg = .gray },
                .key_style = .{ .bold = true, .fg = .gray },
            });
        }

        if (width > size_width + 1) {
            _ = surface.copyTextAt(width - size_width, 0, size_text, .{ .fg = .gray }) catch {};
        }
    }

    fn viewRepoPicker(self: *const App, surface: *chasen.Surface) !void {
        const modal = ui.Modal.init(.{});
        const opts: ui.Modal.ViewOptions = .{
            .dialog_width = 64,
            .dialog_height = 14,
            .title = "Repositories",
            .border = .rounded,
            .title_style = .{ .bold = true, .fg = .{ .index = 14 } },
        };
        modal.view(surface, opts);

        const content_rect = ui.Modal.contentRect(surface, opts);
        if (content_rect.width == 0 or content_rect.height == 0) return;
        var content = surface.child(content_rect);
        const size = content.size();

        _ = content.borrowTextAt(0, 0, "filter: ", .{ .fg = .{ .index = 11 }, .bold = true });
        _ = content.copyTextAt(8, 0, self.repo_picker_input.slice(), .{ .fg = .{ .index = 11 } }) catch {};
        if (self.repo_picker_no_match and size.width > 20) {
            _ = content.borrowTextAt(20, 0, "(no match)", .{ .fg = .{ .index = 9 } });
        }

        if (size.height <= 2) return;
        const rows = size.height - 2;
        const focused = self.repo_picker_filter.list.focusedIndex();
        const range = ui.ListViewport.visibleRange(self.repo_picker_filter.labels.len, focused, rows);
        var row: u16 = 2;
        var visible_index: usize = range.start;
        while (visible_index < range.end) : ({
            visible_index += 1;
            row += 1;
        }) {
            const source_index = self.repo_picker_filter.sourceIndex(visible_index) orelse continue;
            const label = self.repo_picker_filter.labels[visible_index];
            const focused_row = visible_index == focused;
            const active = source_index == self.active_repo;
            const style: chasen.TextStyle = if (focused_row)
                .{ .reverse = true, .bold = true }
            else if (active)
                .{ .fg = .{ .index = 10 }, .bold = true }
            else
                .{};
            const marker = if (focused_row) ">" else " ";
            const active_marker = if (active) "*" else " ";
            _ = content.borrowTextAt(0, row, marker, style);
            _ = content.borrowTextAt(2, row, active_marker, style);
            var label_area = content.child(.{
                .col = 4,
                .row = row,
                .width = if (size.width > 4) size.width - 4 else 0,
                .height = 1,
            });
            _ = try label_area.copyTextAt(0, 0, label, style);
        }
    }

    fn footerItems(self: *const App) []const ui.key_hint.Item {
        return switch (self.focus) {
            .sidebar => &footer_sidebar_items,
            .diff => &footer_diff_items,
        };
    }

    fn drawSearchMatchMarker(self: *const App, surface: *chasen.Surface) void {
        const match_offset = self.search_match_offset orelse return;
        if (match_offset < self.diff_scroll) return;

        const visible_offset = match_offset - self.diff_scroll;
        const body_rows = diff_render.visibleBodyRows(surface.size().height);
        if (visible_offset >= body_rows) return;

        const row: u16 = @intCast(diff_body_start_row + visible_offset);
        _ = surface.borrowTextAt(0, row, ">", .{ .bold = true, .reverse = true, .fg = .{ .index = 11 } });
    }

    fn startRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const task = try ctx.allocator().create(RepoDiscoveryTask);
        errdefer ctx.allocator().destroy(task);

        self.load_generation +%= 1;
        self.load_in_flight = false;
        self.load_in_flight_generation = null;
        task.* = .{ .generation = self.load_generation };
        self.clearLoadedDiff();
        self.load_state = .loading;
        ctx.task().spawnWith(task, RepoDiscoveryTask.run) catch |err| {
            self.load_state = .{ .failed = "Could not start repo discovery task" };
            return err;
        };
    }

    fn finishRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg), finished: RepoDiscoveryFinished) !void {
        var result = finished.result;
        defer result.deinit(ctx.allocator());

        if (finished.generation != self.load_generation) return;

        switch (result) {
            .empty => unreachable,
            .discovered => |discovery| {
                result = .empty;
                self.clearRepoDiscovery(ctx.allocator());
                self.repo_discovery_result = discovery;
                self.active_repo = 0;

                if (self.activeRepoRoot() == null) {
                    self.clearLoadedDiff();
                    self.load_state = .{ .empty = .no_repository };
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
            self.load_state = .{ .empty = switch (err) {
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

        self.load_generation +%= 1;
        task.* = .{
            // Source payloads come from process args, so clone the request
            // before the async task crosses the update boundary.
            .request = request,
            .generation = self.load_generation,
        };

        if (clear_visible_state) {
            self.clearLoadedDiff();
            self.load_state = .loading;
        }
        self.load_in_flight = true;
        self.load_in_flight_generation = self.load_generation;
        ctx.task().spawnWith(task, DiffLoadTask.run) catch |err| {
            self.load_state = .{ .failed = "Could not start diff load task" };
            self.load_in_flight = false;
            self.load_in_flight_generation = null;
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
            }, self.load_state == .idle);
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
        if (self.repo_picker_mode or self.search_mode or self.file_search_mode) {
            ctx.redraw().skip();
            return;
        }
        if (self.load_in_flight or self.load_state == .loading) {
            ctx.redraw().skip();
            return;
        }

        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx);
        } else {
            try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
                ctx.redraw().skip();
                return;
            }, self.load_state == .idle);
        }
    }

    fn repoRootForCurrentSource(self: *const App) error{MissingRepoRoot}!?[]const u8 {
        if (!diff_source.sourceRequiresRepo(self.config.source)) return null;
        return self.activeRepoRoot() orelse error.MissingRepoRoot;
    }

    fn activeRepoRoot(self: *const App) ?[]const u8 {
        const discovery = self.repo_discovery_result orelse return null;
        return switch (discovery) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => |workspace| if (self.active_repo < workspace.repos.len)
                workspace.repos[self.active_repo].canonical_root
            else
                null,
            .none => null,
        };
    }

    fn needsRepoDiscovery(self: *const App) bool {
        const discovery = self.repo_discovery_result orelse return true;
        return discovery == .none;
    }

    fn finishDiffLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: DiffLoadFinished) !void {
        if (self.allocator == null) self.allocator = ctx.allocator();

        var result = finished.result;
        defer result.deinit(ctx.allocator());

        // Multiple reloads can be in flight. Only the newest generation is
        // allowed to update visible state.
        if (self.load_in_flight_generation == finished.generation) {
            self.load_in_flight = false;
            self.load_in_flight_generation = null;
        }
        if (finished.generation != self.load_generation) return;

        self.clearLoadedDiff();

        switch (result) {
            .empty => self.load_state = .{ .empty = .no_changes },
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
                // load_state, clearLoadedDiff owns the materialized reviewed
                // slice and load arena.
                self.load_arena = arena;
                self.load_state = .{ .loaded = loaded };
                self.active_reviewed_files_owned = true;

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
        self.load_arena = arena;
        self.load_state = .{ .failed = if (copied.len > 0) copied else "Unknown diff load error" };
    }

    fn clearLoadedDiff(self: *App) void {
        if (self.active_reviewed_files_owned) {
            if (self.allocator) |allocator| {
                if (self.activeLoadedDiff()) |loaded| allocator.free(loaded.reviewed_files);
            }
        }
        self.active_reviewed_files_owned = false;
        if (self.load_arena) |*arena| arena.deinit();
        self.load_arena = null;
        self.load_state = .idle;
        self.diff_scroll = 0;
        self.selected_hunk = 0;
        self.clearSearchMatch();
    }

    fn selectFileDelta(self: *App, delta: i2) void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (loaded.document.files.len == 0 or loaded.tree.nodes.len == 0) return;

        if (delta < 0) {
            if (loaded.previousVisibleNodeIndex(self.selected_node)) |previous| {
                self.selectSidebarNode(loaded, previous);
            }
        } else if (loaded.nextVisibleNodeIndex(self.selected_node)) |next| {
            self.selectSidebarNode(loaded, next);
        }
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
    }

    fn selectFileAbsolute(self: *App, index: usize) void {
        const file_count = self.loadedFileCount() orelse return;
        if (file_count == 0) return;
        const target = @min(index, file_count - 1);
        if (self.selected_file == target) {
            if (self.activeLoadedDiff()) |loaded| {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            self.clampSelection(file_count);
            return;
        }
        self.selected_file = target;
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
        const previous_file = self.selected_file;
        self.selected_node = node_index;
        // File rows change the active diff pane file. Directory rows only move
        // the sidebar cursor and keep the previous file visible.
        if (loaded.tree.nodes[node_index].file_index) |file_index| {
            self.selected_file = file_index;
            if (self.selected_file != previous_file) {
                self.resetDiffPosition();
                self.refreshSearchForSelectedFile();
            }
        }
    }

    fn toggleSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.selected_node];
        if (node.kind != .directory) return;
        const allocator = self.loadArenaAllocator() orelse return;
        try file_tree.toggle(allocator, &loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(allocator, self.hide_reviewed_files, self.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn expandSelectedDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.selected_node];
        if (node.kind != .directory) return;
        file_tree.expand(&loaded.collapsed_dirs, node.path);
        try loaded.rebuildVisibleNodes(self.loadArenaAllocator() orelse return, self.hide_reviewed_files, self.changed_file_filter);
        self.clampSelection(loaded.document.files.len);
    }

    fn collapseOrSelectParentDirectory(self: *App) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.selected_node >= loaded.tree.nodes.len) return;
        const node = loaded.tree.nodes[self.selected_node];
        if (node.kind == .directory and !file_tree.isCollapsed(&loaded.collapsed_dirs, node.path)) {
            const allocator = self.loadArenaAllocator() orelse return;
            try file_tree.collapse(allocator, &loaded.collapsed_dirs, node.path);
            try loaded.rebuildVisibleNodes(allocator, self.hide_reviewed_files, self.changed_file_filter);
            self.clampSelection(loaded.document.files.len);
            return;
        }
        if (parentDirectoryNodeIndex(loaded.tree, self.selected_node)) |parent| {
            self.selected_node = parent;
            self.clampSelection(loaded.document.files.len);
        }
    }

    fn scrollDiff(self: *App, delta: i2) void {
        if (delta < 0) {
            self.diff_scroll -|= 1;
        } else {
            self.diff_scroll += 1;
        }
        self.clampDiffNavigation();
    }

    fn pageDiff(self: *App, delta: i2) void {
        const rows = self.diffVisibleRows();
        const step: usize = @max(rows, 1);
        if (delta < 0) {
            self.diff_scroll -|= step;
        } else {
            self.diff_scroll += step;
        }
        self.clampDiffNavigation();
    }

    fn selectHunkDelta(self: *App, delta: i2) void {
        const file = self.selectedFile() orelse return;
        if (file.hunks.len == 0) return;

        if (delta < 0) {
            if (self.selected_hunk > 0) self.selected_hunk -= 1;
        } else if (self.selected_hunk + 1 < file.hunks.len) {
            self.selected_hunk += 1;
        }

        self.scrollSelectedHunkIntoView();
        self.clampDiffNavigation();
    }

    fn toggleSelectedHunkFold(self: *App) void {
        const loaded = self.activeLoadedDiff() orelse return;
        const file_index = self.selectedFileIndex(loaded) orelse return;
        if (file_index >= loaded.document.files.len) return;
        const file = loaded.document.files[file_index];
        if (self.selected_hunk >= file.hunks.len) return;

        if (!loaded.isHunkFolded(file_index, self.selected_hunk) and
            self.currentSearchMatchInHunkBody(self.selected_hunk))
        {
            return;
        }

        loaded.toggleHunkFold(file_index, self.selected_hunk);
        self.updateSearchMatchOffset();
        self.scrollSelectedHunkIntoView();
        self.clampDiffNavigation();
    }

    fn scrollSelectedHunkIntoView(self: *App) void {
        const mode = self.effectiveDisplayMode();
        const target = self.selectedHunkOffset(mode, self.selected_hunk);
        const visible_rows = self.diffVisibleRows();
        if (target < self.diff_scroll) {
            self.diff_scroll = target;
        } else if (visible_rows > 0 and target >= self.diff_scroll + visible_rows) {
            self.diff_scroll = target + 1 - visible_rows;
        }
    }

    fn clampDiffNavigation(self: *App) void {
        const file = self.selectedFile() orelse {
            self.resetDiffPosition();
            return;
        };

        if (file.hunks.len == 0) {
            self.selected_hunk = 0;
        } else if (self.selected_hunk >= file.hunks.len) {
            self.selected_hunk = file.hunks.len - 1;
        }

        const mode = self.effectiveDisplayMode();
        const line_count = self.selectedFileLineIndex(mode).lineCount();
        const visible_rows = self.diffVisibleRows();
        const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
        if (self.diff_scroll > max_scroll) self.diff_scroll = max_scroll;
    }

    fn clampDiffNavigationKeepingHunkVisible(self: *App) void {
        self.clampDiffNavigation();
        if (self.selectedFile()) |file| {
            if (file.hunks.len > 0) self.scrollSelectedHunkIntoView();
        }
        self.clampDiffNavigation();
    }

    fn resetDiffPosition(self: *App) void {
        self.diff_scroll = 0;
        self.selected_hunk = 0;
        self.clearSearchMatch();
    }

    fn enterSearchMode(self: *App) void {
        self.search_input = self.search_query;
        self.search_mode = true;
    }

    fn cancelSearchMode(self: *App) void {
        self.search_input = self.search_query;
        self.search_mode = false;
    }

    fn clearSearch(self: *App) void {
        self.search_mode = false;
        self.search_input = .{};
        self.search_query = .{};
        self.clearSearchMatch();
    }

    fn enterFileSearchMode(self: *App) void {
        self.file_search_return_focus = self.focus;
        self.focus = .sidebar;
        self.file_search_mode = true;
        self.file_search_input = .{};
        self.file_search_no_match = false;
    }

    fn cancelFileSearchMode(self: *App, allocator: std.mem.Allocator) void {
        self.file_search_mode = false;
        self.file_search_input = .{};
        self.file_search_filter.deinit(allocator);
        self.file_search_no_match = false;
        self.focus = self.file_search_return_focus;
    }

    fn enterRepoPickerMode(self: *App, allocator: std.mem.Allocator) !void {
        if (self.workspaceRepos() == null) return;

        self.repo_picker_mode = true;
        self.repo_picker_input = .{};
        self.repo_picker_no_match = false;
        try self.refreshRepoPickerFilter(allocator);
        self.focusRepoPickerOnActive();
    }

    fn cancelRepoPickerMode(self: *App, allocator: std.mem.Allocator) void {
        self.repo_picker_mode = false;
        self.repo_picker_input = .{};
        self.repo_picker_filter.deinit(allocator);
        self.repo_picker_no_match = false;
    }

    fn submitRepoPicker(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const focused = self.repo_picker_filter.list.focusedIndex();
        const repo_index = self.repo_picker_filter.sourceIndex(focused) orelse {
            self.repo_picker_no_match = true;
            return;
        };
        const repos = self.workspaceRepos() orelse return;
        if (repo_index >= repos.len) {
            self.repo_picker_no_match = true;
            return;
        }

        self.cancelRepoPickerMode(ctx.allocator());
        if (repo_index == self.active_repo) return;

        try self.startDiffLoadWithRepoRoot(ctx, repos[repo_index].canonical_root, true);
        self.active_repo = repo_index;
        self.selected_file = 0;
        self.selected_node = 0;
        self.clearSearch();
    }

    fn refreshRepoPickerFilter(self: *App, allocator: std.mem.Allocator) !void {
        const repos = self.workspaceRepos() orelse return;

        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(allocator);

        for (repos) |repo| {
            try labels.append(allocator, repo.display_path);
        }

        // ListFilter owns the filtered index arrays; repository labels remain
        // borrowed from the current discovery result.
        try self.repo_picker_filter.apply(allocator, labels.items, self.repo_picker_input.slice());
    }

    fn focusRepoPickerOnActive(self: *App) void {
        var visible_index: usize = 0;
        while (visible_index < self.repo_picker_filter.labels.len) : (visible_index += 1) {
            const source_index = self.repo_picker_filter.sourceIndex(visible_index) orelse continue;
            if (source_index != self.active_repo) continue;
            while (self.repo_picker_filter.list.focusedIndex() < visible_index) {
                self.repo_picker_filter.update(.move_next);
            }
            return;
        }
    }

    fn toggleReviewedFile(self: *App, allocator: std.mem.Allocator) !void {
        const loaded = self.activeLoadedDiff() orelse return;
        if (self.selected_node >= loaded.tree.nodes.len) return;

        const node = loaded.tree.nodes[self.selected_node];
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
        const query = std.mem.trim(u8, self.file_search_input.slice(), " \t\r\n");
        if (query.len == 0) {
            self.cancelFileSearchMode(allocator);
            return;
        }

        const loaded = self.activeLoadedDiff() orelse {
            self.file_search_no_match = true;
            return;
        };
        const node_index = try self.findFileNodeWithFilter(allocator, loaded, query) orelse {
            self.file_search_filter.deinit(allocator);
            self.file_search_no_match = true;
            return;
        };

        // Go-to-file should land on the file row, not on a still-collapsed
        // parent directory that hides the matched path.
        file_tree.expandAncestors(&loaded.collapsed_dirs, loaded.tree.nodes[node_index].path);
        const load_allocator = self.loadArenaAllocator() orelse {
            self.file_search_filter.deinit(allocator);
            return;
        };
        loaded.rebuildVisibleNodes(load_allocator, self.hide_reviewed_files, self.changed_file_filter) catch {
            self.file_search_filter.deinit(allocator);
            self.file_search_no_match = true;
            return;
        };
        self.selectSidebarNode(loaded, node_index);
        self.clampSelection(loaded.document.files.len);
        self.clampDiffNavigation();
        self.cancelFileSearchMode(allocator);
    }

    fn submitSearch(self: *App) void {
        self.search_mode = false;
        self.search_query = self.search_input;
        self.clearSearchMatch();
        if (self.search_query.len == 0) {
            return;
        }
        self.selectSearchMatch(.forward);
    }

    fn selectSearchMatch(self: *App, direction: diff_search.Direction) void {
        const file = self.selectedFile() orelse return;
        if (self.search_query.len == 0) return;

        const line_count = self.selectedFileLineIndex(self.effectiveDisplayMode()).lineCount();
        if (line_count == 0) return;
        const base = if (self.search_match) |match| match.coordinate else null;
        const next = diff_search.findMatch(file, self.effectiveDisplayMode(), self.search_query.slice(), base, direction) orelse {
            self.clearSearchMatch();
            return;
        };
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        if (self.search_match_offset) |offset| self.diff_scroll = offset;
        self.clampDiffNavigation();
    }

    fn refreshSearchForSelectedFile(self: *App) void {
        self.clearSearchMatch();
        if (self.search_query.len == 0) return;
        const file = self.selectedFile() orelse return;
        const next = diff_search.findMatch(file, self.effectiveDisplayMode(), self.search_query.slice(), null, .forward) orelse return;
        self.unfoldSearchMatchIfNeeded(next);
        self.setSearchMatch(next);
        if (self.search_match_offset) |offset| self.diff_scroll = offset;
    }

    fn clearSearchMatch(self: *App) void {
        self.search_match = null;
        self.search_match_offset = null;
    }

    fn setSearchMatch(self: *App, match: diff_search.Match) void {
        self.search_match = match;
        self.updateSearchMatchOffset();
    }

    fn updateSearchMatchOffset(self: *App) void {
        self.search_match_offset = null;
        const match = self.search_match orelse return;
        const file = self.selectedFile() orelse return;
        const mode = self.effectiveDisplayMode();
        const offset = diff_view_model.renderedOffsetForCoordinate(file, mode, match.coordinate, self.selectedFileCachedLineIndex(mode)) orelse {
            self.clearSearchMatch();
            return;
        };
        self.search_match_offset = offset;
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
        const match = self.search_match orelse return false;
        return switch (match.coordinate) {
            .hunk_line => |line| line.hunk_index == hunk_index,
            else => false,
        };
    }

    fn scrollSearchMatchIntoView(self: *App) void {
        const offset = self.search_match_offset orelse return;
        const visible_rows = self.diffVisibleRows();
        if (offset < self.diff_scroll) {
            self.diff_scroll = offset;
        } else if (visible_rows > 0 and offset >= self.diff_scroll + visible_rows) {
            self.diff_scroll = offset + 1 - visible_rows;
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
        return diff_render.effectiveMode(self.diffPaneWidth(), self.display_mode);
    }

    fn diffVisibleRows(self: *const App) usize {
        return diff_render.visibleBodyRows(terminalBodyHeight(self.terminal_size.height));
    }

    fn diffPaneWidth(self: *const App) u16 {
        const width = self.terminal_size.width;
        const sidebar_width = sidebarWidth(width);
        if (width <= sidebar_width + 1) return 0;
        return contentWidth(width - sidebar_width - 1);
    }

    fn clampSelection(self: *App, file_count: usize) void {
        if (file_count == 0) {
            self.selected_file = 0;
            self.selected_node = 0;
            return;
        }
        if (self.selected_file >= file_count) self.selected_file = file_count - 1;
        if (self.activeLoadedDiff()) |loaded| {
            if (self.selected_node >= loaded.tree.nodes.len) {
                self.syncSidebarNodeToSelectedFile(loaded);
            }
            if (loaded.visibleAncestorOrSelf(self.selected_node)) |visible_node| {
                self.selected_node = visible_node;
            } else if (loaded.tree.selectedNodeIndex(self.selected_file)) |file_node| {
                self.selected_node = file_node;
            }
        }
    }

    fn reconcileSelectionAfterVisibleNodeChange(self: *App, loaded: *LoadedDiff) void {
        if (loaded.visibleRowOfNode(self.selected_node) != null) {
            return;
        }

        if (loaded.firstVisibleFileNode()) |file_node| {
            self.selectSidebarNode(loaded, file_node);
            return;
        }

        if (loaded.visibleAncestorOrSelf(self.selected_node)) |visible_node| {
            self.selectSidebarNode(loaded, visible_node);
            return;
        }

        if (loaded.visibleNodeAt(0)) |node_index| {
            self.selected_node = node_index;
        }
    }

    fn selectedFileIndex(self: *const App, loaded: *const LoadedDiff) ?usize {
        if (loaded.document.files.len == 0) return null;
        return @min(self.selected_file, loaded.document.files.len - 1);
    }

    fn syncSidebarNodeToSelectedFile(self: *App, loaded: *const LoadedDiff) void {
        const file_index = self.selectedFileIndex(loaded) orelse {
            self.selected_node = 0;
            return;
        };
        self.selected_node = loaded.tree.selectedNodeIndex(file_index) orelse 0;
    }

    fn materializeReviewedFiles(self: *App, allocator: std.mem.Allocator, loaded: *LoadedDiff) !void {
        const reviewed_files = try allocator.alloc(bool, loaded.document.files.len);
        errdefer allocator.free(reviewed_files);

        for (loaded.document.files, 0..) |file, index| {
            reviewed_files[index] = try self.reviewed_store.containsFile(allocator, self.activeRepoRoot(), file);
        }
        loaded.reviewed_files = reviewed_files;
    }

    fn clearRepoDiscovery(self: *App, allocator: std.mem.Allocator) void {
        if (self.repo_discovery_result) |*discovery| discovery.deinit(allocator);
        self.repo_discovery_result = null;
        self.active_repo = 0;
    }

    fn workspaceRepos(self: *const App) ?[]const repo_discovery.RepoEntry {
        const discovery = self.repo_discovery_result orelse return null;
        return switch (discovery) {
            .workspace => |workspace| workspace.repos,
            .single_repo, .none => null,
        };
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
        try self.file_search_filter.applyWithSourceIndexes(allocator, labels.items, node_indexes.items, query);
        return self.file_search_filter.sourceIndex(0);
    }

    fn loadedDiff(self: *App) ?*LoadedDiff {
        return self.activeLoadedDiff();
    }

    fn activeLoadedDiff(self: *App) ?*LoadedDiff {
        return switch (self.load_state) {
            .loaded => |*loaded| loaded,
            else => null,
        };
    }

    fn activeLoadedDiffConst(self: *const App) ?*const LoadedDiff {
        return switch (self.load_state) {
            .loaded => |*loaded| loaded,
            else => null,
        };
    }

    fn loadArenaAllocator(self: *App) ?std.mem.Allocator {
        if (self.load_arena) |*arena| return arena.allocator();
        return null;
    }
};

const footer_rows: u16 = 1;
const sidebar_header_rows: u16 = 3;
const diff_body_start_row: u16 = 3;

const footer_sidebar_items = [_]ui.key_hint.Item{
    ui.key_hint.item("Tab", "focus"),
    ui.key_hint.item("↑/↓/j/k", "move"),
    ui.key_hint.item("Enter/←/→", "fold"),
    ui.key_hint.item("/", "search"),
    ui.key_hint.item("f", "file"),
    ui.key_hint.item("R", "repo"),
    ui.key_hint.item("F", "filter"),
    ui.key_hint.item("v", "viewed"),
    ui.key_hint.item("H", "hide viewed"),
    ui.key_hint.item("e", "edit"),
    ui.key_hint.item("n/p", "hunk/search"),
    ui.key_hint.item("u", "mode"),
    ui.key_hint.item("r", "reload"),
    ui.key_hint.item("q", "quit"),
};

const footer_diff_items = [_]ui.key_hint.Item{
    ui.key_hint.item("Tab", "focus"),
    ui.key_hint.item("↑/↓/j/k", "scroll"),
    ui.key_hint.item("Enter", "fold"),
    ui.key_hint.item("/", "search"),
    ui.key_hint.item("f", "file"),
    ui.key_hint.item("R", "repo"),
    ui.key_hint.item("v", "viewed"),
    ui.key_hint.item("H", "hide viewed"),
    ui.key_hint.item("e", "edit"),
    ui.key_hint.item("n/p", "hunk/search"),
    ui.key_hint.item("u", "mode"),
    ui.key_hint.item("r", "reload"),
    ui.key_hint.item("q", "quit"),
};

fn diffContentSurface(surface: *chasen.Surface) chasen.Surface {
    const size = surface.size();
    if (size.width <= search_marker_gutter_width) {
        return surface.child(.{ .col = 0, .row = 0, .width = size.width, .height = size.height });
    }
    return surface.child(.{
        .col = search_marker_gutter_width,
        .row = 0,
        .width = size.width - search_marker_gutter_width,
        .height = size.height,
    });
}

fn contentWidth(width: u16) u16 {
    return if (width > search_marker_gutter_width) width - search_marker_gutter_width else width;
}

const search_marker_gutter_width: u16 = 1;

const SearchQuery = struct {
    buffer: [128]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const SearchQuery) []const u8 {
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

const Focus = enum {
    sidebar,
    diff,

    fn toggled(self: Focus) Focus {
        return switch (self) {
            .sidebar => .diff,
            .diff => .sidebar,
        };
    }
};

fn statusStyle(status: file_tree.Status, selected: bool) chasen.TextStyle {
    const fg: chasen.Color = switch (status) {
        .modified => .{ .index = 11 },
        .added => .{ .index = 2 },
        .deleted => .{ .index = 9 },
        .renamed => .{ .index = 14 },
        .binary => .{ .index = 13 },
    };
    return .{ .fg = fg, .bold = true, .reverse = selected };
}

fn reviewedStyle(selected: bool) chasen.TextStyle {
    return .{ .fg = .{ .index = 2 }, .bold = true, .reverse = selected };
}

fn modeBadgeStyle(selected: bool) chasen.TextStyle {
    return .{ .fg = .{ .index = 12 }, .bold = true, .reverse = selected };
}

fn terminalBodyHeight(terminal_height: u16) u16 {
    return if (terminal_height > footer_rows) terminal_height - footer_rows else 0;
}

fn sidebarWidth(total_width: u16) u16 {
    if (total_width < 50) return @min(total_width, 24);
    if (total_width < 90) return 28;
    return 34;
}

fn isSearchCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint != 0x7f and !(codepoint >= 0x80 and codepoint <= 0x9f);
}

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

const DiffLoadFinished = struct {
    generation: u64,
    result: DiffLoadTaskResult,
};

const RepoDiscoveryFinished = struct {
    generation: u64,
    result: RepoDiscoveryTaskResult,
};

const RepoDiscoveryTaskResult = union(enum) {
    empty,
    discovered: repo_discovery.DiscoveryResult,
    failed: []u8,
    failed_static: []const u8,

    fn deinit(self: *RepoDiscoveryTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .discovered => |*discovery| discovery.deinit(allocator),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

const DiffLoadTaskResult = union(enum) {
    empty,
    loaded: LoadedDiffBundle,
    failed: []u8,
    failed_static: []const u8,

    fn deinit(self: *DiffLoadTaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .empty, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(),
            .failed => |message| allocator.free(message),
        }
        self.* = .empty;
    }
};

const LoadedDiffBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    loaded: LoadedDiff,

    fn deinit(self: *LoadedDiffBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }

    fn takeArena(self: *LoadedDiffBundle) std.heap.ArenaAllocator {
        const arena = self.arena.?;
        self.arena = null;
        return arena;
    }
};

const RepoDiscoveryTask = struct {
    generation: u64,

    fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) App.Msg {
        const task: *RepoDiscoveryTask = @ptrCast(@alignCast(ctx_ptr));
        defer allocator.destroy(task);

        return .{ .repos_discovered = .{
            .generation = task.generation,
            .result = runDiscovery(allocator, io),
        } };
    }

    fn runDiscovery(allocator: std.mem.Allocator, io: std.Io) RepoDiscoveryTaskResult {
        const result = repo_discovery.discover(allocator, io) catch |err| {
            return .{
                .failed = std.fmt.allocPrint(allocator, "Repo discovery failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Repo discovery failed: OutOfMemory" },
            };
        };
        return .{ .discovered = result };
    }
};

const DiffLoadTask = struct {
    request: LoadRequest,
    generation: u64,

    fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) App.Msg {
        const task: *DiffLoadTask = @ptrCast(@alignCast(ctx_ptr));
        defer {
            diff_source.freeLoadRequest(allocator, task.request);
            allocator.destroy(task);
        }

        return .{ .diff_loaded = .{
            .generation = task.generation,
            .result = runLoad(task, allocator, io),
        } };
    }

    fn runLoad(task: *DiffLoadTask, allocator: std.mem.Allocator, io: std.Io) DiffLoadTaskResult {
        const raw_result = diff_source.load(allocator, io, task.request) catch |err| {
            return .{
                .failed = std.fmt.allocPrint(allocator, "Diff load failed: {s}", .{@errorName(err)}) catch
                    return .{ .failed_static = "Diff load failed: OutOfMemory" },
            };
        };

        switch (raw_result) {
            .ok => |bytes| {
                defer allocator.free(bytes);
                if (bytes.len == 0) return .empty;
                const bundle = buildLoadedBundle(allocator, bytes) catch |err| {
                    return .{ .failed = std.fmt.allocPrint(allocator, "Diff parse failed: {s}", .{@errorName(err)}) catch
                        return .{ .failed_static = "Diff parse failed: OutOfMemory" } };
                };
                return .{ .loaded = bundle };
            },
            .failed => |message| return .{ .failed = message },
            .failed_static => |message| return .{ .failed_static = message },
        }
    }

    fn buildLoadedBundle(allocator: std.mem.Allocator, bytes: []const u8) !LoadedDiffBundle {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const copied = try arena_allocator.dupe(u8, bytes);
        const document = try diff_parser.parse(arena_allocator, copied);
        const tree = try file_tree.build(arena_allocator, document);
        const rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document);
        const collapsed_hunks = try arena_allocator.alloc(bool, document.totalHunks());
        @memset(collapsed_hunks, false);
        var loaded: LoadedDiff = .{
            .bytes = copied.len,
            .lines = countLines(copied),
            .text = copied,
            .document = document,
            .tree = tree,
            .rendered_line_cache = rendered_line_cache,
            .collapsed_hunks = collapsed_hunks,
            .collapsed_dirs = .empty,
        };
        try loaded.rebuildVisibleNodes(arena_allocator, false, .all);

        // Do not store `arena_allocator` in the result: its interface points
        // at this local arena value, while the arena itself is moved by value
        // across the task-result boundary.
        return .{ .arena = arena, .loaded = loaded };
    }
};

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;

    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

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
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo"));
}

test "file selection boundary does not reset diff position" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .diff_scroll = 4,
        .selected_hunk = 1,
    };

    app.selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);
    try std.testing.expectEqual(@as(usize, 4), app.diff_scroll);
    try std.testing.expectEqual(@as(usize, 1), app.selected_hunk);

    app.selectFileAbsolute(0);
    try std.testing.expectEqual(@as(usize, 4), app.diff_scroll);
    try std.testing.expectEqual(@as(usize, 1), app.selected_hunk);
}

test "mode toggle keeps selected hunk visible" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .display_mode = .unified,
        .selected_hunk = 1,
    };

    app.scrollSelectedHunkIntoView();
    try std.testing.expect(app.diff_scroll > 0);

    app.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();

    const file = testFileWithHunks();
    const target = diff_render.hunkBodyLineOffset(file, app.effectiveDisplayMode(), app.selected_hunk);
    const visible_rows = app.diffVisibleRows();
    try std.testing.expect(target >= app.diff_scroll);
    try std.testing.expect(visible_rows == 0 or target < app.diff_scroll + visible_rows);
}

test "mode change resyncs search match to rendered body offsets" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 12 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .display_mode = .unified,
    };
    setSearchQuery(&app, "late new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 12), app.search_match_offset);

    app.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 10), app.search_match_offset);
    try std.testing.expect(app.search_match_offset.? >= app.diff_scroll);
    try std.testing.expect(app.search_match_offset.? < app.diff_scroll + app.diffVisibleRows());
}

test "mode change keeps search near later matches" {
    var app: App = .{
        .terminal_size = .{ .width = 140, .height = 8 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .display_mode = .unified,
    };
    setSearchQuery(&app, "new");

    app.submitSearch();
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search_match_offset);
    app.selectSearchMatch(.forward);
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 12), app.search_match_offset);

    app.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();
    app.updateSearchMatchOffset();

    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 1, .line_index = 2 } });
    try std.testing.expectEqual(@as(?usize, 10), app.search_match_offset);
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
        .load_arena = arena,
        .load_state = .{ .loaded = loaded },
        .selected_hunk = 0,
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
        .load_arena = arena,
        .load_state = .{ .loaded = loaded },
    };
    defer app.clearLoadedDiff();
    setSearchQuery(&app, "new");

    app.submitSearch();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search_match_offset);
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
        .load_arena = arena,
        .load_state = .{ .loaded = loaded },
    };
    defer app.clearLoadedDiff();
    setSearchQuery(&app, "new");
    app.submitSearch();

    app.toggleSelectedHunkFold();

    const active = app.loadedDiff().?;
    try std.testing.expect(!active.isHunkFolded(0, 0));
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search_match_offset);
}

test "file change resyncs retained search query to selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_state = .{ .loaded = testLoadedDiffTwo() },
        .display_mode = .unified,
    };
    setSearchQuery(&app, "target");

    app.selectFileAbsolute(1);

    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
    try expectSearchCoordinate(&app, .{ .metadata = 0 });
    try std.testing.expectEqual(@as(?usize, 0), app.search_match_offset);
    try std.testing.expectEqual(@as(usize, 0), app.diff_scroll);
}

test "sidebar navigation can select directories without changing selected file" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_state = .{ .loaded = testLoadedDiffNested() },
        .selected_file = 0,
        .selected_node = 1,
    };

    app.selectFileDelta(-1);
    try std.testing.expectEqual(@as(usize, 0), app.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);

    app.selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 1), app.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);

    app.selectFileDelta(1);
    try std.testing.expectEqual(@as(usize, 2), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
}

test "toggling selected directory collapses visible descendants" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = testLoadedDiffNested() },
        .selected_file = 0,
        .selected_node = 0,
    };
    defer app.clearLoadedDiff();

    try app.toggleSelectedDirectory();

    const loaded = app.load_state.loaded;
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 1), loaded.tree.visibleNodeCount(&loaded.collapsed_dirs));
    try std.testing.expect(loaded.visible_nodes.len >= loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(usize, 0), app.selected_node);
}

test "file search selects matching file and expands ancestors" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = testLoadedDiffNested() },
        .selected_file = 0,
        .selected_node = 0,
        .file_search_mode = true,
    };
    defer app.clearLoadedDiff();

    var loaded = app.loadedDiff().?;
    try file_tree.collapse(app.loadArenaAllocator().?, &loaded.collapsed_dirs, "src");
    setFileSearchInput(&app, "src/b");

    try app.submitFileSearch(std.testing.allocator);

    loaded = app.loadedDiff().?;
    try std.testing.expect(!file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
    try std.testing.expectEqual(@as(usize, 2), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
    try std.testing.expect(!app.file_search_mode);
}

test "file search keeps prompt open on no match" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_state = .{ .loaded = testLoadedDiffNested() },
        .file_search_mode = true,
    };
    setFileSearchInput(&app, "missing");

    defer app.file_search_filter.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search_mode);
    try std.testing.expect(app.file_search_no_match);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);
}

test "file search skips hidden reviewed matches" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .file_search_mode = true,
        .hide_reviewed_files = true,
    };
    defer app.clearLoadedDiff();
    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, true, .all);
    setFileSearchInput(&app, "src");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search_mode);
    try std.testing.expect(!app.file_search_no_match);
    try std.testing.expectEqual(@as(usize, 2), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
}

test "file search trims empty input and restores focus on cancel" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 12 },
        .load_state = .{ .loaded = testLoadedDiffNested() },
        .focus = .diff,
    };

    app.enterFileSearchMode();
    try std.testing.expectEqual(Focus.sidebar, app.focus);
    setFileSearchInput(&app, "   ");

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(!app.file_search_mode);
    try std.testing.expectEqual(Focus.diff, app.focus);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);
}

test "sidebar renders file status badges" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load_state = .{ .loaded = testLoadedDiffTwoWithStatuses() },
    };

    try app.viewSidebar(&ts.surface, app.load_state.loaded);

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
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_one },
            .tree = .{ .nodes = &nodes },
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
    };

    try app.viewSidebar(&ts.surface, app.load_state.loaded);

    try ts.expectCellText(2, sidebar_header_rows, "M");
    try ts.expectCellText(4, sidebar_header_rows, "m");
}

test "changed file filter keeps only matching status rows" {
    var app: App = .{
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = testLoadedDiffTwoWithStatuses() },
        .changed_file_filter = .added,
        .selected_node = 1,
        .selected_file = 1,
    };
    defer app.clearLoadedDiff();

    try app.loadedDiff().?.rebuildVisibleNodes(app.loadArenaAllocator().?, false, app.changed_file_filter);

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 1), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
}

test "finishDiffLoad applies active changed file filter" {
    var app: App = .{
        .load_generation = 1,
        .changed_file_filter = .added,
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try DiffLoadTask.buildLoadedBundle(std.testing.allocator, test_diff_added_deleted);
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
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = testLoadedDiffTwoWithStatuses() },
        .selected_node = 1,
        .selected_file = 1,
    };
    defer app.clearLoadedDiff();

    try app.cycleChangedFileFilter();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(ChangedFileFilter.modified, app.changed_file_filter);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 1), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
}

test "file search skips files outside active changed filter" {
    var app: App = .{
        .load_state = .{ .loaded = testLoadedDiffTwoWithStatuses() },
        .file_search_mode = true,
        .changed_file_filter = .added,
    };
    setFileSearchInput(&app, "deleted");
    defer app.file_search_filter.deinit(std.testing.allocator);

    try app.submitFileSearch(std.testing.allocator);

    try std.testing.expect(app.file_search_mode);
    try std.testing.expect(app.file_search_no_match);
    try std.testing.expectEqual(@as(usize, 0), app.selected_file);
}

test "toggleReviewedFile marks only selected file nodes" {
    var reviewed = [_]bool{ false, false };
    var app: App = .{
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .selected_node = 0,
        .selected_file = 0,
    };
    defer app.reviewed_store.deinit(std.testing.allocator);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);

    app.selected_node = 1;
    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &reviewed);

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &reviewed);
}

test "reviewed state survives active loaded diff replacement" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .load_state = .{ .loaded = testLoadedDiffTwo() },
        .selected_node = 0,
        .selected_file = 0,
    };
    defer app.clearLoadedDiff();
    defer app.reviewed_store.deinit(std.testing.allocator);

    var loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.active_reviewed_files_owned = true;

    try app.toggleReviewedFile(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded.reviewed_files);

    app.clearLoadedDiff();
    app.load_state = .{ .loaded = testLoadedDiffTwo() };
    loaded = app.loadedDiff().?;
    try app.materializeReviewedFiles(std.testing.allocator, loaded);
    app.active_reviewed_files_owned = true;

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
        .repo_discovery_result = .{ .workspace = .{
            .current_root = try allocator.dupe(u8, "/work"),
            .repos = repos,
        } },
        .active_repo = 0,
    };
    defer app.clearRepoDiscovery(allocator);
    defer app.reviewed_store.deinit(allocator);

    try app.reviewed_store.set(allocator, app.activeRepoRoot(), test_files_two[0], true);

    var loaded_one = testLoadedDiffTwo();
    try app.materializeReviewedFiles(allocator, &loaded_one);
    defer allocator.free(loaded_one.reviewed_files);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, loaded_one.reviewed_files);

    app.active_repo = 1;
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
        .repo_discovery_result = .{ .workspace = .{
            .current_root = try allocator.dupe(u8, "/work"),
            .repos = repos,
        } },
        .active_repo = 1,
    };
    defer app.clearRepoDiscovery(allocator);
    defer app.repo_picker_filter.deinit(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker_mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker_filter.labels.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker_filter.list.focusedIndex());
}

test "sidebar renders reviewed marker" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    var reviewed = [_]bool{ true, false };
    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two_statuses },
            .tree = .{ .nodes = &test_tree_two_status_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
    };

    try app.viewSidebar(&ts.surface, app.load_state.loaded);

    try ts.expectCellText(1, sidebar_header_rows, "✓");
    try ts.expectCellText(4, sidebar_header_rows, "A");
}

test "hide reviewed files removes reviewed file rows from visible list" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .selected_node = 1,
        .selected_file = 0,
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expect(app.hide_reviewed_files);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 2), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(@as(usize, 2), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
}

test "hide reviewed files removes directories with no visible file descendants" {
    var reviewed = [_]bool{ true, true };
    var app: App = .{
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .selected_node = 1,
        .selected_file = 0,
    };
    defer app.clearLoadedDiff();

    try app.toggleHideReviewedFiles();

    const loaded = app.loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());
}

test "hide reviewed files keeps directories for non-contiguous unreviewed descendants" {
    var reviewed = [_]bool{ true, false };
    var app: App = .{
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_non_contiguous_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .selected_node = 1,
        .selected_file = 0,
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
        .load_arena = .init(std.testing.allocator),
        .load_state = .{ .loaded = .{
            .text = "",
            .document = .{ .files = &test_files_two },
            .tree = .{ .nodes = &test_tree_nested_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        } },
        .selected_node = 1,
        .selected_file = 0,
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
    try std.testing.expectEqual(@as(usize, 2), app.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.selected_file);
}

test "search match marker is drawn on visible match row" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 80, .height = 9 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .search_match_offset = 4,
        .diff_scroll = 3,
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
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .search_match_offset = 0,
    };

    try app.viewDiffPane(&ts.surface, app.load_state.loaded);

    try ts.expectCellText(0, diff_body_start_row, ">");
    try ts.expectCellText(1, diff_body_start_row, "i");
}

test "status mode label uses diff content width after marker gutter" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(72, 8);
    defer ts.deinit();

    const app: App = .{
        .terminal_size = .{ .width = 72, .height = 9 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .display_mode = .side_by_side,
    };

    try app.viewDiffPane(&ts.surface, app.load_state.loaded);

    try ts.expectCellText(14, 2, "u");
    try ts.expectCellText(15, 2, "n");
    try ts.expectCellText(16, 2, "i");
}

test "search input header does not show no match before submit" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .search_mode = true,
    };
    setSearchInput(&app, "missing");

    try app.viewDiffPane(&ts.surface, app.load_state.loaded);

    try ts.expectCellText(0, 2, "s");
    try ts.expectCellText(8, 2, "m");
    try ts.expectCellText(15, 2, " ");
}

test "canceling edited search restores committed query and match" {
    var app: App = .{
        .terminal_size = .{ .width = 90, .height = 11 },
        .load_state = .{ .loaded = testLoadedDiffOne() },
        .search_match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } },
        .search_match_offset = 7,
    };
    setSearchQuery(&app, "new");

    app.enterSearchMode();
    app.search_input.backspace();
    try app.search_input.insert('x');
    app.cancelSearchMode();

    try std.testing.expectEqualStrings("new", app.search_query.slice());
    try std.testing.expectEqualStrings("new", app.search_input.slice());
    try expectSearchCoordinate(&app, .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } });
    try std.testing.expectEqual(@as(?usize, 7), app.search_match_offset);
}

test "finishDiffLoad takes current loaded bundle ownership" {
    var app: App = .{ .load_generation = 1 };
    defer app.clearLoadedDiff();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try DiffLoadTask.buildLoadedBundle(std.testing.allocator, test_diff_one);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.load_arena != null);
    try std.testing.expect(app.load_state == .loaded);
    try std.testing.expectEqual(@as(usize, 1), app.load_state.loaded.document.files.len);
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: App = .{ .load_generation = 2 };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try DiffLoadTask.buildLoadedBundle(std.testing.allocator, test_diff_one);
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.load_arena == null);
    try std.testing.expect(app.load_state == .idle);
}

test "finishDiffLoad records empty diff as no changes" {
    var app: App = .{ .load_generation = 1 };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .empty,
    });

    try std.testing.expect(app.load_state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.load_state.empty);
}

test "finishRepoDiscovery records no repository as empty state" {
    var app: App = .{ .load_generation = 1 };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer app.clearRepoDiscovery(std.testing.allocator);

    try app.finishRepoDiscovery(&ctx, .{
        .generation = 1,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try std.testing.allocator.dupe(u8, "/work"),
        } } },
    });

    try std.testing.expect(app.load_state == .empty);
    try std.testing.expectEqual(EmptyReason.no_repository, app.load_state.empty);
}

test "finishDiffLoad copies and frees current failed message" {
    var app: App = .{ .load_generation = 1 };
    defer app.clearLoadedDiff();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const message = try std.testing.allocator.dupe(u8, " failed \n");
    try app.finishDiffLoad(&ctx, .{
        .generation = 1,
        .result = .{ .failed = message },
    });

    try std.testing.expect(app.load_arena != null);
    try std.testing.expectEqualStrings("failed", app.load_state.failed);
}

fn expectSearchCoordinate(app: *const App, expected: diff_view_model.BodyCoordinate) !void {
    try std.testing.expect(app.search_match != null);
    try std.testing.expect(std.meta.eql(expected, app.search_match.?.coordinate));
}

fn setSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.search_query.buffer[0..query.len], query);
    app.search_query.len = query.len;
    setSearchInput(app, query);
}

fn setSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.search_input.buffer[0..query.len], query);
    app.search_input.len = query.len;
}

fn setFileSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.file_search_input.buffer[0..query.len], query);
    app.file_search_input.len = query.len;
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
