const std = @import("std");
const chasen = @import("chasen");
const diff_parser = @import("diff_parser.zig");
const diff_render = @import("diff_render.zig");
const diff_source = @import("diff_source.zig");

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

pub const App = struct {
    config: CliConfig = .{},
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    load_state: LoadState = .idle,
    selected_file: usize = 0,
    sidebar_scroll: usize = 0,
    focus: Focus = .sidebar,
    diff_scroll: usize = 0,
    selected_hunk: usize = 0,
    display_mode: diff_render.DisplayMode = .side_by_side,
    /// Owns the currently loaded raw diff, parsed document arrays, and error
    /// messages. Recreated on every successful load/reload.
    load_arena: ?std.heap.ArenaAllocator = null,
    /// Monotonic id used to ignore stale async task results after reload.
    load_generation: u64 = 0,

    pub const Msg = union(enum) {
        terminal_resized: chasen.Size,
        diff_loaded: DiffLoadFinished,
        select_previous_file,
        select_next_file,
        scroll_diff_up,
        scroll_diff_down,
        page_diff_up,
        page_diff_down,
        select_previous_hunk,
        select_next_hunk,
        select_first_file,
        select_last_file,
        toggle_focus,
        toggle_display_mode,
        reload,
        quit,
    };

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        try self.startDiffLoad(ctx);
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        _ = deinit_ctx;
        self.clearLoadedDiff();
    }

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .terminal_resized => |size| {
                self.terminal_size = size;
                self.clampDiffNavigationKeepingHunkVisible();
            },
            .diff_loaded => |finished| try self.finishDiffLoad(ctx, finished),
            .select_previous_file => self.selectFileDelta(-1),
            .select_next_file => self.selectFileDelta(1),
            .scroll_diff_up => self.scrollDiff(-1),
            .scroll_diff_down => self.scrollDiff(1),
            .page_diff_up => self.pageDiff(-1),
            .page_diff_down => self.pageDiff(1),
            .select_previous_hunk => self.selectHunkDelta(-1),
            .select_next_hunk => self.selectHunkDelta(1),
            .select_first_file => self.selectFileAbsolute(0),
            .select_last_file => self.selectLastFile(),
            .toggle_focus => self.focus = self.focus.toggled(),
            .toggle_display_mode => {
                self.display_mode = self.display_mode.toggled();
                self.clampDiffNavigationKeepingHunkVisible();
            },
            .reload => try self.startDiffLoad(ctx),
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
        if (key.matches(chasen.Key.tab, .{})) return .toggle_focus;
        if (key.matches(chasen.Key.page_up, .{})) return .page_diff_up;
        if (key.matches(chasen.Key.page_down, .{})) return .page_diff_down;
        if (key.matches(chasen.Key.home, .{})) return .select_first_file;
        if (key.matches(chasen.Key.end, .{})) return .select_last_file;

        return switch (key.codepoint) {
            'k', chasen.Key.up => if (self.focus == .diff) .scroll_diff_up else .select_previous_file,
            'j', chasen.Key.down => if (self.focus == .diff) .scroll_diff_down else .select_next_file,
            'n' => .select_next_hunk,
            'p' => .select_previous_hunk,
            'g' => .select_first_file,
            'G' => .select_last_file,
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

        if (size.height <= sidebar_header_rows) return;

        const visible_rows: usize = size.height - sidebar_header_rows;
        const start = @min(self.sidebar_scroll, loaded.document.files.len);
        const end = @min(start + visible_rows, loaded.document.files.len);
        var row: u16 = sidebar_header_rows;
        var index: usize = start;
        while (index < end) : ({
            index += 1;
            row += 1;
        }) {
            const file = loaded.document.files[index];
            const selected = index == self.selected_file;
            const stats = diff_render.fileStats(file);
            const style: chasen.TextStyle = if (selected)
                .{ .reverse = true, .bold = true }
            else
                .{};
            const marker = if (selected) ">" else " ";
            _ = surface.borrowTextAt(0, row, marker, style);
            _ = try surface.copyTextAt(2, row, diff_render.displayPath(file), style);
            if (surface.size().width > 12) {
                _ = try surface.printAt(surface.size().width - 10, row, style, "+{d} -{d}", .{ stats.added, stats.removed });
            }
        }
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
        const mode = diff_render.effectiveMode(surface.size().width, self.display_mode);
        const focus_label = if (self.focus == .diff) "diff" else "sidebar";
        _ = try surface.printAt(0, 2, .{ .fg = .gray }, "{d}/{d}  {d} hunks  {s}  focus:{s}  scroll:{d}", .{
            selected + 1,
            loaded.document.files.len,
            file.hunks.len,
            mode.label(),
            focus_label,
            self.diff_scroll,
        });
        try diff_render.renderFile(surface, file, .{
            .requested_mode = self.display_mode,
            .scroll = self.diff_scroll,
            .highlighted_hunk = if (file.hunks.len > 0) self.selected_hunk else null,
        });
    }

    fn viewLoadState(self: *const App, col: *chasen.Column) !void {
        switch (self.load_state) {
            .idle => col.borrowText("Waiting to load diff.", .{ .fg = .gray }),
            .loading => col.borrowText("Loading diff...", .{ .fg = .{ .index = 11 } }),
            .empty => col.borrowText("No changes found.", .{ .fg = .gray }),
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

        var col: u16 = 0;
        _ = surface.borrowTextAt(col, 0, "gitframe", .{ .bold = true });
        col +|= 9;
        _ = surface.borrowTextAt(col, 0, "viewer shell", .{ .fg = .gray });
        col +|= 13;
        _ = surface.borrowTextAt(col, 0, "Tab focus  j/k move  n/p hunk  u mode  r reload  q quit", .{ .fg = .gray });

        const size_text = std.fmt.allocPrint(surface.frameAllocator(), "{d}x{d}", .{
            self.terminal_size.width,
            self.terminal_size.height,
        }) catch return;
        const size_width: u16 = @intCast(@min(chasen.text.displayWidth(size_text), std.math.maxInt(u16)));
        if (width > size_width + 1) {
            _ = surface.copyTextAt(width - size_width, 0, size_text, .{ .fg = .gray }) catch {};
        }
    }

    fn startDiffLoad(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const task = try ctx.allocator().create(DiffLoadTask);
        errdefer ctx.allocator().destroy(task);
        self.load_generation +%= 1;
        task.* = .{
            // Source payloads come from process args, so clone them before the
            // async task crosses the update boundary.
            .source = try diff_source.cloneSource(ctx.allocator(), self.config.source),
            .generation = self.load_generation,
        };
        errdefer diff_source.freeSource(ctx.allocator(), task.source);

        self.clearLoadedDiff();
        self.load_state = .loading;
        ctx.spawnWith(task, DiffLoadTask.run) catch |err| {
            self.load_state = .{ .failed = "Could not start diff load task" };
            return err;
        };
    }

    fn finishDiffLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: DiffLoadFinished) !void {
        defer finished.result.deinit(ctx.allocator());
        // Multiple reloads can be in flight. Only the newest generation is
        // allowed to update visible state.
        if (finished.generation != self.load_generation) return;

        self.clearLoadedDiff();

        var arena: std.heap.ArenaAllocator = .init(ctx.allocator());
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        switch (finished.result) {
            .ok => |bytes| {
                // The task allocator owns `bytes`; copy into the app arena so
                // parsed line/path slices can safely point into the raw text.
                const copied = try arena_allocator.dupe(u8, bytes);
                if (copied.len == 0) {
                    self.load_state = .empty;
                    arena.deinit();
                    return;
                }
                const document = diff_parser.parse(arena_allocator, copied) catch |err| {
                    const message = try std.fmt.allocPrint(arena_allocator, "Diff parse failed: {s}", .{@errorName(err)});
                    self.load_arena = arena;
                    self.load_state = .{ .failed = message };
                    return;
                };

                self.load_arena = arena;
                self.clampSelection(document.files.len);
                self.load_state = .{ .loaded = .{
                    .bytes = copied.len,
                    .lines = countLines(copied),
                    .text = copied,
                    .document = document,
                } };
                self.clampDiffNavigation();
            },
            .failed => |message| {
                const copied = try arena_allocator.dupe(u8, std.mem.trim(u8, message, " \t\r\n"));
                self.load_arena = arena;
                self.load_state = .{ .failed = if (copied.len > 0) copied else "Unknown diff load error" };
            },
            .failed_static => |message| {
                const copied = try arena_allocator.dupe(u8, message);
                self.load_arena = arena;
                self.load_state = .{ .failed = copied };
            },
        }
    }

    fn clearLoadedDiff(self: *App) void {
        if (self.load_arena) |*arena| arena.deinit();
        self.load_arena = null;
        self.load_state = .idle;
        self.diff_scroll = 0;
        self.selected_hunk = 0;
    }

    fn selectFileDelta(self: *App, delta: i2) void {
        const file_count = switch (self.load_state) {
            .loaded => |loaded| loaded.document.files.len,
            else => return,
        };
        if (file_count == 0) return;

        const previous_file = self.selected_file;
        if (delta < 0) {
            if (self.selected_file > 0) self.selected_file -= 1;
        } else if (self.selected_file + 1 < file_count) {
            self.selected_file += 1;
        }
        if (self.selected_file != previous_file) self.resetDiffPosition();
        self.clampSelection(file_count);
        self.clampDiffNavigation();
    }

    fn selectFileAbsolute(self: *App, index: usize) void {
        const file_count = self.loadedFileCount() orelse return;
        if (file_count == 0) return;
        const target = @min(index, file_count - 1);
        if (self.selected_file == target) return;
        self.selected_file = target;
        self.resetDiffPosition();
        self.clampSelection(file_count);
        self.clampDiffNavigation();
    }

    fn selectLastFile(self: *App) void {
        const file_count = self.loadedFileCount() orelse return;
        if (file_count == 0) return;
        self.selectFileAbsolute(file_count - 1);
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

        self.scrollSelectedHunkIntoView(file);
        self.clampDiffNavigation();
    }

    fn scrollSelectedHunkIntoView(self: *App, file: diff_parser.FileDiff) void {
        const mode = self.effectiveDisplayMode();
        const target = diff_render.hunkBodyLineOffset(file, mode, self.selected_hunk);
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
        const line_count = diff_render.renderedBodyLineCount(file, mode);
        const visible_rows = self.diffVisibleRows();
        const max_scroll = if (line_count > visible_rows) line_count - visible_rows else 0;
        if (self.diff_scroll > max_scroll) self.diff_scroll = max_scroll;
    }

    fn clampDiffNavigationKeepingHunkVisible(self: *App) void {
        self.clampDiffNavigation();
        if (self.selectedFile()) |file| {
            if (file.hunks.len > 0) self.scrollSelectedHunkIntoView(file);
        }
        self.clampDiffNavigation();
    }

    fn resetDiffPosition(self: *App) void {
        self.diff_scroll = 0;
        self.selected_hunk = 0;
    }

    fn selectedFile(self: *const App) ?diff_parser.FileDiff {
        return switch (self.load_state) {
            .loaded => |loaded| if (loaded.document.files.len == 0)
                null
            else
                loaded.document.files[@min(self.selected_file, loaded.document.files.len - 1)],
            else => null,
        };
    }

    fn loadedFileCount(self: *const App) ?usize {
        return switch (self.load_state) {
            .loaded => |loaded| loaded.document.files.len,
            else => null,
        };
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
        return if (width > sidebar_width + 1) width - sidebar_width - 1 else 0;
    }

    fn clampSelection(self: *App, file_count: usize) void {
        if (file_count == 0) {
            self.selected_file = 0;
            self.sidebar_scroll = 0;
            return;
        }
        if (self.selected_file >= file_count) self.selected_file = file_count - 1;
        if (self.sidebar_scroll > self.selected_file) self.sidebar_scroll = self.selected_file;
        const body_height = terminalBodyHeight(self.terminal_size.height);
        const visible_rows: usize = if (body_height > sidebar_header_rows)
            body_height - sidebar_header_rows
        else
            1;
        if (self.selected_file >= self.sidebar_scroll + visible_rows) {
            self.sidebar_scroll = self.selected_file + 1 - visible_rows;
        }
    }
};

const footer_rows: u16 = 1;
const sidebar_header_rows: u16 = 3;

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

fn terminalBodyHeight(terminal_height: u16) u16 {
    return if (terminal_height > footer_rows) terminal_height - footer_rows else 0;
}

fn sidebarWidth(total_width: u16) u16 {
    if (total_width < 50) return @min(total_width, 24);
    if (total_width < 90) return 28;
    return 34;
}

const LoadState = union(enum) {
    idle,
    loading,
    empty,
    loaded: LoadedDiff,
    failed: []const u8,
};

const LoadedDiff = struct {
    text: []const u8,
    document: diff_parser.DiffDocument,
    bytes: usize,
    lines: usize,
};

const DiffLoadFinished = struct {
    generation: u64,
    result: diff_source.LoadResult,
};

const DiffLoadTask = struct {
    source: SourceMode,
    generation: u64,

    fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) App.Msg {
        const task: *DiffLoadTask = @ptrCast(@alignCast(ctx_ptr));
        defer {
            diff_source.freeSource(allocator, task.source);
            allocator.destroy(task);
        }

        // The returned LoadResult transfers any allocated payload to App.update,
        // where it is copied into app-owned storage and then deinitialized.
        const result: diff_source.LoadResult = diff_source.load(allocator, io, task.source) catch |err| .{
            .failed = std.fmt.allocPrint(allocator, "Diff load failed: {s}", .{@errorName(err)}) catch
                return .{ .diff_loaded = .{
                    .generation = task.generation,
                    .result = .{ .failed_static = "Diff load failed: OutOfMemory" },
                } },
        };
        return .{ .diff_loaded = .{
            .generation = task.generation,
            .result = result,
        } };
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

test "countLines handles empty and trailing newline inputs" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo"));
}

test "file selection boundary does not reset diff position" {
    var app: App = .{
        .terminal_size = .{ .width = 100, .height = 8 },
        .load_state = .{ .loaded = .{
            .text = "",
            .bytes = 0,
            .lines = 0,
            .document = .{ .files = &.{testFileWithHunks()} },
        } },
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
        .load_state = .{ .loaded = .{
            .text = "",
            .bytes = 0,
            .lines = 0,
            .document = .{ .files = &.{testFileWithHunks()} },
        } },
        .display_mode = .unified,
        .selected_hunk = 1,
    };

    app.scrollSelectedHunkIntoView(testFileWithHunks());
    try std.testing.expect(app.diff_scroll > 0);

    app.display_mode = .side_by_side;
    app.clampDiffNavigationKeepingHunkVisible();

    const file = testFileWithHunks();
    const target = diff_render.hunkBodyLineOffset(file, app.effectiveDisplayMode(), app.selected_hunk);
    const visible_rows = app.diffVisibleRows();
    try std.testing.expect(target >= app.diff_scroll);
    try std.testing.expect(visible_rows == 0 or target < app.diff_scroll + visible_rows);
}

fn testFileWithHunks() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 5,
                .new_start = 1,
                .new_count = 5,
                .section = "first",
                .lines = &.{
                    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                    .{ .kind = .context, .text = "two", .old_line = 2, .new_line = 2 },
                    .{ .kind = .removed, .text = "old", .old_line = 3 },
                    .{ .kind = .added, .text = "new", .new_line = 3 },
                    .{ .kind = .context, .text = "four", .old_line = 4, .new_line = 4 },
                },
            },
            .{
                .old_start = 20,
                .old_count = 3,
                .new_start = 20,
                .new_count = 3,
                .section = "second",
                .lines = &.{
                    .{ .kind = .context, .text = "late one", .old_line = 20, .new_line = 20 },
                    .{ .kind = .removed, .text = "late old", .old_line = 21 },
                    .{ .kind = .added, .text = "late new", .new_line = 21 },
                },
            },
        },
    };
}
