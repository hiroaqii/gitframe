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
            .terminal_resized => |size| self.terminal_size = size,
            .diff_loaded => |finished| try self.finishDiffLoad(ctx, finished),
            .select_previous_file => self.selectFileDelta(-1),
            .select_next_file => self.selectFileDelta(1),
            .toggle_display_mode => self.display_mode = self.display_mode.toggled(),
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
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'k', chasen.Key.up => .select_previous_file,
                'j', chasen.Key.down => .select_next_file,
                'u' => .toggle_display_mode,
                'q' => .quit,
                'r' => .reload,
                else => null,
            },
            .winsize => |winsize| .{ .terminal_resized = .{
                .width = winsize.cols,
                .height = winsize.rows,
            } },
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

        _ = surface.borrowTextAt(0, 0, "Files", .{ .bold = true, .fg = .{ .index = 14 } });
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
        _ = try surface.printAt(0, 2, .{ .fg = .gray }, "{d}/{d}  {d} hunks  {s}", .{
            selected + 1,
            loaded.document.files.len,
            file.hunks.len,
            mode.label(),
        });
        try diff_render.renderFile(surface, file, .{ .requested_mode = self.display_mode });
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
        _ = surface.borrowTextAt(col, 0, "j/k select  u mode  r reload  q quit", .{ .fg = .gray });

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
    }

    fn selectFileDelta(self: *App, delta: i2) void {
        const file_count = switch (self.load_state) {
            .loaded => |loaded| loaded.document.files.len,
            else => return,
        };
        if (file_count == 0) return;

        if (delta < 0) {
            if (self.selected_file > 0) self.selected_file -= 1;
        } else if (self.selected_file + 1 < file_count) {
            self.selected_file += 1;
        }
        self.clampSelection(file_count);
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
