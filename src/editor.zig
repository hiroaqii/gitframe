const std = @import("std");
const config = @import("config.zig");

/// Maximum argv entries passed to the foreground editor command.
///
/// Configured argv over this size is invalid. The legacy env fallback still
/// truncates before appending the target path to preserve prior behavior.
pub const max_argv = config.editor_max_argv;

pub const BuildError = error{
    EmptyArgv,
    MissingPathPlaceholder,
    UnknownPlaceholder,
    TooManyArguments,
} || std.mem.Allocator.Error;

pub const Target = struct {
    repo_root: []const u8,
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

pub const BuildResult = struct {
    argv: []const []const u8 = &.{},
    owned_args: []?[]u8 = &.{},

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        freeOwnedArgs(allocator, self.owned_args);
        allocator.free(self.owned_args);
        allocator.free(self.argv);
        self.* = .{};
    }
};

/// Builds editor argv from GitFrame config or `$VISUAL` / `$EDITOR` / `vi`.
///
/// Configured argv is expanded into owned strings because placeholders can
/// produce new arguments. Env fallback borrows command tokens and owns a
/// prefixed file operand when needed. Both paths use the same deinit contract.
pub fn build(
    allocator: std.mem.Allocator,
    user_config: config.EditorConfig,
    env_map: ?*std.process.Environ.Map,
    target: Target,
) BuildError!BuildResult {
    if (user_config.argv_len > 0) {
        return try buildConfigured(allocator, user_config, target);
    }
    return try buildFromEnvironment(allocator, env_map, target);
}

fn buildConfigured(
    allocator: std.mem.Allocator,
    user_config: config.EditorConfig,
    target: Target,
) BuildError!BuildResult {
    const template = user_config.argvSlice();
    if (template.len == 0) return error.EmptyArgv;
    if (template.len > max_argv) return error.TooManyArguments;
    if (template[0].len == 0) return error.EmptyArgv;

    var has_path = false;
    var argv = try allocator.alloc([]const u8, template.len);
    errdefer allocator.free(argv);
    var owned_args = try allocator.alloc(?[]u8, template.len);
    @memset(owned_args, null);
    errdefer {
        freeOwnedArgs(allocator, owned_args);
        allocator.free(owned_args);
    }

    for (template, 0..) |arg, index| {
        if (std.mem.indexOf(u8, arg, "{path}") != null) has_path = true;
        const expanded = try expandArgument(allocator, arg, target);
        argv[index] = expanded;
        owned_args[index] = expanded;
    }
    if (!has_path) return error.MissingPathPlaceholder;

    return .{
        .argv = argv,
        .owned_args = owned_args,
    };
}

fn buildFromEnvironment(
    allocator: std.mem.Allocator,
    env_map: ?*std.process.Environ.Map,
    target: Target,
) BuildError!BuildResult {
    var stack: [max_argv][]const u8 = undefined;
    const legacy = legacyArgv(env_map, target.path, &stack);

    const argv = try allocator.alloc([]const u8, legacy.len);
    errdefer allocator.free(argv);
    const owned_args = try allocator.alloc(?[]u8, legacy.len);
    errdefer allocator.free(owned_args);
    @memset(owned_args, null);
    @memcpy(argv, legacy);

    if (pathNeedsPrefix(target.path)) {
        const path = try std.fmt.allocPrint(allocator, "./{s}", .{target.path});
        argv[argv.len - 1] = path;
        owned_args[argv.len - 1] = path;
    }

    return .{
        .argv = argv,
        .owned_args = owned_args,
    };
}

fn freeOwnedArgs(allocator: std.mem.Allocator, owned_args: []?[]u8) void {
    for (owned_args) |owned| {
        if (owned) |arg| allocator.free(arg);
    }
}

fn expandArgument(
    allocator: std.mem.Allocator,
    template: []const u8,
    target: Target,
) BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, template, cursor, '{')) |open| {
        out.writer.writeAll(template[cursor..open]) catch return error.OutOfMemory;
        const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse return error.UnknownPlaceholder;
        const placeholder = template[open .. close + 1];
        try writePlaceholder(&out.writer, placeholder, target);
        cursor = close + 1;
    }
    if (std.mem.indexOfScalarPos(u8, template, cursor, '}') != null) return error.UnknownPlaceholder;
    out.writer.writeAll(template[cursor..]) catch return error.OutOfMemory;

    return try out.toOwnedSlice();
}

fn writePlaceholder(writer: *std.Io.Writer, placeholder: []const u8, target: Target) BuildError!void {
    if (std.mem.eql(u8, placeholder, "{path}")) {
        if (pathNeedsPrefix(target.path)) writer.writeAll("./") catch return error.OutOfMemory;
        writer.writeAll(target.path) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, placeholder, "{line}")) {
        writer.print("{d}", .{target.line orelse 1}) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, placeholder, "{column}")) {
        writer.print("{d}", .{target.column orelse 1}) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, placeholder, "{repo_root}")) {
        writer.writeAll(target.repo_root) catch return error.OutOfMemory;
    } else {
        return error.UnknownPlaceholder;
    }
}

/// A leading '+' is a vi-style command and '-' may introduce an option.
/// './' keeps these relative paths literal without changing explicit argv flags.
fn pathNeedsPrefix(path: []const u8) bool {
    return path.len > 0 and (path[0] == '+' or path[0] == '-');
}

fn legacyArgv(env_map: ?*std.process.Environ.Map, target_path: []const u8, out: *[max_argv][]const u8) []const []const u8 {
    const cmd = command(env_map);
    var index: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (tokens.next()) |token| {
        if (index + 1 >= out.len) break;
        out[index] = token;
        index += 1;
    }
    if (index == 0) {
        out[0] = "vi";
        index = 1;
    }
    out[index] = target_path;
    return out[0 .. index + 1];
}

fn command(env_map: ?*std.process.Environ.Map) []const u8 {
    if (env_map) |map| {
        if (nonEmptyEnv(map, "VISUAL")) |visual| return visual;
        if (nonEmptyEnv(map, "EDITOR")) |editor| return editor;
    }
    return "vi";
}

fn nonEmptyEnv(env_map: *std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env_map.get(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else null;
}

test "build falls back to vi and appends target path" {
    var result = try build(std.testing.allocator, .{}, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.argv.len);
    try std.testing.expectEqualStrings("vi", result.argv[0]);
    try std.testing.expectEqualStrings("src/main.zig", result.argv[1]);
}

test "configured argv wins and expands placeholders" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "nvim";
    editor_config.argv[1] = "+{line}";
    editor_config.argv[2] = "{repo_root}/{path}:{column}";
    editor_config.argv_len = 3;

    var result = try build(std.testing.allocator, editor_config, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
        .line = 42,
        .column = 7,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("nvim", result.argv[0]);
    try std.testing.expectEqualStrings("+42", result.argv[1]);
    try std.testing.expectEqualStrings("/repo/src/main.zig:7", result.argv[2]);
}

test "configured argv requires path placeholder" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "nvim";
    editor_config.argv[1] = "+{line}";
    editor_config.argv_len = 2;

    try std.testing.expectError(error.MissingPathPlaceholder, build(std.testing.allocator, editor_config, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
    }));
}

test "configured argv rejects unknown placeholders" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "nvim";
    editor_config.argv[1] = "{path}";
    editor_config.argv[2] = "{unknown}";
    editor_config.argv_len = 3;

    try std.testing.expectError(error.UnknownPlaceholder, build(std.testing.allocator, editor_config, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
    }));
}

test "configured argv rejects empty command" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "";
    editor_config.argv[1] = "{path}";
    editor_config.argv_len = 2;

    try std.testing.expectError(error.EmptyArgv, build(std.testing.allocator, editor_config, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
    }));
}

test "editor argv construction releases every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, configured: bool) !void {
            var editor_config: config.EditorConfig = .{};
            editor_config.argv[0] = "nvim";
            editor_config.argv[1] = "+{line}";
            editor_config.argv[2] = "{path}:{column}";
            editor_config.argv_len = if (configured) 3 else 0;
            var result = try build(allocator, editor_config, null, .{
                .repo_root = "/repo",
                .path = "+file.zig",
                .line = 42,
                .column = 7,
            });
            defer result.deinit(allocator);
        }
    };
    for ([_]bool{ false, true }) |configured| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{configured});
    }
}

test "editor file operands stay literal in configured and environment argv" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("VISUAL", "nvim --clean +42");
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "nvim";
    editor_config.argv[1] = "--clean";
    editor_config.argv[2] = "+{line}";
    editor_config.argv[3] = "{path}";
    editor_config.argv_len = 4;

    for ([_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "+call writefile(['executed'],'marker')", .expected = "./+call writefile(['executed'],'marker')" },
        .{ .path = "--help", .expected = "./--help" },
        .{ .path = "space name.txt", .expected = "space name.txt" },
        .{ .path = "quote'\".txt", .expected = "quote'\".txt" },
        .{ .path = "src/main.zig", .expected = "src/main.zig" },
        .{ .path = "./+already-prefixed", .expected = "./+already-prefixed" },
        .{ .path = "/repo/-absolute", .expected = "/repo/-absolute" },
    }) |case| {
        for ([_]config.EditorConfig{ .{}, editor_config }) |settings| {
            var result = try build(std.testing.allocator, settings, &env, .{
                .repo_root = "/repo",
                .path = case.path,
                .line = 42,
            });
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 4), result.argv.len);
            try std.testing.expectEqualStrings("nvim", result.argv[0]);
            try std.testing.expectEqualStrings("--clean", result.argv[1]);
            try std.testing.expectEqualStrings("+42", result.argv[2]);
            try std.testing.expectEqualStrings(case.expected, result.argv[3]);
        }
    }
}
