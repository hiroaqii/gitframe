const std = @import("std");
const chasen = @import("chasen");

pub const SourceMode = union(enum) {
    unstaged,
    cached,
    stdin,
    patch_file: []const u8,
    range: []const u8,
};

pub const CliConfig = struct {
    source: SourceMode = .unstaged,

    pub fn sourceLabel(self: CliConfig) []const u8 {
        return switch (self.source) {
            .unstaged => "unstaged changes",
            .cached => "staged changes",
            .stdin => "stdin diff",
            .patch_file => |path| path,
            .range => |range| range,
        };
    }
};

pub const App = struct {
    config: CliConfig = .{},
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },

    pub const Msg = union(enum) {
        terminal_resized: chasen.Size,
        reload,
        quit,
    };

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .terminal_resized => |size| self.terminal_size = size,
            .reload => {},
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
        col.borrowText("Diff acquisition and parser are next roadmap slices.", .{});
        col.borrowText("Keys: r reload, q quit", .{ .fg = .gray });
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
};

pub const ParseArgsError = error{
    UnknownOption,
    MissingOptionValue,
    TooManyInputs,
    ConflictingSourceMode,
};

pub fn parseArgs(args: []const []const u8) ParseArgsError!CliConfig {
    var config: CliConfig = .{};
    var input_count: usize = 0;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--cached")) {
            try setSourceMode(&config, .cached);
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            try setSourceMode(&config, .stdin);
        } else if (std.mem.eql(u8, arg, "--range")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            try setSourceMode(&config, .{ .range = args[index] });
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            const value = arg["--range=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            try setSourceMode(&config, .{ .range = value });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            input_count += 1;
            if (input_count > 1) return error.TooManyInputs;
            try setSourceMode(&config, .{ .patch_file = arg });
        }
    }

    return config;
}

fn setSourceMode(config: *CliConfig, source: SourceMode) ParseArgsError!void {
    if (config.source != .unstaged) return error.ConflictingSourceMode;
    config.source = source;
}

test "parseArgs defaults to unstaged diff" {
    const args = [_][]const u8{"gitframe"};
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .unstaged);
}

test "parseArgs accepts cached mode" {
    const args = [_][]const u8{ "gitframe", "--cached" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .cached);
}

test "parseArgs accepts stdin mode" {
    const args = [_][]const u8{ "gitframe", "--stdin" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .stdin);
}

test "parseArgs accepts range option" {
    const args = [_][]const u8{ "gitframe", "--range", "main...HEAD" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .range);
    try std.testing.expectEqualStrings("main...HEAD", config.source.range);
}

test "parseArgs accepts patch file path" {
    const args = [_][]const u8{ "gitframe", "change.diff" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .patch_file);
    try std.testing.expectEqualStrings("change.diff", config.source.patch_file);
}

test "parseArgs rejects conflicting source modes" {
    const stdin_and_file = [_][]const u8{ "gitframe", "--stdin", "change.diff" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(stdin_and_file[0..]));

    const cached_and_range = [_][]const u8{ "gitframe", "--cached", "--range", "main...HEAD" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(cached_and_range[0..]));

    const range_and_stdin = [_][]const u8{ "gitframe", "--range=main...HEAD", "--stdin" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(range_and_stdin[0..]));
}
