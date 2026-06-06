const std = @import("std");
const chasen = @import("chasen");
const diff_source = @import("diff_source.zig");

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

pub const App = struct {
    config: CliConfig = .{},
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    load_state: LoadState = .idle,
    load_arena: ?std.heap.ArenaAllocator = null,
    load_generation: u64 = 0,

    pub const Msg = union(enum) {
        terminal_resized: chasen.Size,
        diff_loaded: DiffLoadFinished,
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
            .reload => try self.startDiffLoad(ctx),
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const App, surface: *chasen.Surface) !void {
        const size = surface.size();
        if (size.width == 0 or size.height == 0) return;

        surface.hideCursor();

        const footer_row = size.height - 1;
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
            .height = 1,
        });
        self.viewFooter(&footer);
    }

    pub fn handleEvent(self: *const App, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
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

    fn viewLoadState(self: *const App, col: *chasen.Column) !void {
        switch (self.load_state) {
            .idle => col.borrowText("Waiting to load diff.", .{ .fg = .gray }),
            .loading => col.borrowText("Loading diff...", .{ .fg = .{ .index = 11 } }),
            .empty => col.borrowText("No changes found.", .{ .fg = .gray }),
            .loaded => |loaded| {
                try col.print("Loaded {d} bytes across {d} lines.", .{ loaded.bytes, loaded.lines });
                col.borrowText("Parser and file sidebar are next roadmap slices.", .{ .fg = .gray });
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
        if (finished.generation != self.load_generation) return;

        self.clearLoadedDiff();

        var arena: std.heap.ArenaAllocator = .init(ctx.allocator());
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        switch (finished.result) {
            .ok => |bytes| {
                const copied = try arena_allocator.dupe(u8, bytes);
                if (copied.len == 0) {
                    self.load_state = .empty;
                    arena.deinit();
                    return;
                }

                self.load_arena = arena;
                self.load_state = .{ .loaded = .{
                    .bytes = copied.len,
                    .lines = countLines(copied),
                    .text = copied,
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
};

const LoadState = union(enum) {
    idle,
    loading,
    empty,
    loaded: LoadedDiff,
    failed: []const u8,
};

const LoadedDiff = struct {
    text: []const u8,
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
