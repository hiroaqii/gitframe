const std = @import("std");
const config = @import("config.zig");

/// Maximum argv entries passed to the foreground editor command.
///
/// Configured argv over this size is invalid. Environment commands truncate
/// before appending the target path to preserve prior behavior.
pub const max_argv = config.editor_max_argv;

pub const BuildError = error{
    EmptyArgv,
    MissingPathPlaceholder,
    UnknownPlaceholder,
    TooManyArguments,
    NoEditorFound,
} || std.mem.Allocator.Error;

pub const Target = struct {
    repo_root: []const u8,
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
};

/// Borrowed page-selected target, consumed synchronously when queuing an editor.
pub const TargetResult = union(enum) {
    ready: Target,
    unavailable_source,
    no_repo,
    no_path,
    directory_unsupported,
    symlink_unsupported,
    deleted_file,
    stale_source,
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

/// Builds editor argv from config, VISUAL, EDITOR, then nvim/vim/vi on PATH.
///
/// Configured argv is expanded into owned strings because placeholders can
/// produce new arguments. Env fallback borrows command tokens and owns a
/// prefixed file operand when needed. Both paths use the same deinit contract.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    user_config: config.EditorConfig,
    env_map: ?*std.process.Environ.Map,
    target: Target,
) BuildError!BuildResult {
    if (user_config.argv_len > 0) {
        return try buildConfigured(allocator, user_config, target);
    }
    return try buildFromEnvironment(allocator, io, env_map, target);
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
    io: std.Io,
    env_map: ?*std.process.Environ.Map,
    target: Target,
) BuildError!BuildResult {
    var stack: [max_argv][]const u8 = undefined;
    var discovered: ?[]u8 = null;
    defer if (discovered) |path| allocator.free(path);
    const command_argv = if (environmentCommand(env_map)) |command|
        environmentArgv(command, target.path, &stack)
    else blk: {
        discovered = try findDefaultEditor(allocator, io, env_map, target.repo_root);
        stack[0] = discovered.?;
        stack[1] = target.path;
        break :blk stack[0..2];
    };

    const argv = try allocator.alloc([]const u8, command_argv.len);
    errdefer allocator.free(argv);
    const owned_args = try allocator.alloc(?[]u8, command_argv.len);
    errdefer allocator.free(owned_args);
    @memset(owned_args, null);
    @memcpy(argv, command_argv);

    if (pathNeedsPrefix(target.path)) {
        const path = try std.fmt.allocPrint(allocator, "./{s}", .{target.path});
        argv[argv.len - 1] = path;
        owned_args[argv.len - 1] = path;
    }
    owned_args[0] = discovered;
    discovered = null;

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

fn environmentArgv(cmd: []const u8, target_path: []const u8, out: *[max_argv][]const u8) []const []const u8 {
    var index: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (tokens.next()) |token| {
        if (index + 1 >= out.len) break;
        out[index] = token;
        index += 1;
    }
    std.debug.assert(index > 0);
    out[index] = target_path;
    return out[0 .. index + 1];
}

fn environmentCommand(env_map: ?*std.process.Environ.Map) ?[]const u8 {
    if (env_map) |map| {
        if (nonEmptyEnv(map, "VISUAL")) |visual| return visual;
        if (nonEmptyEnv(map, "EDITOR")) |editor| return editor;
    }
    return null;
}

fn findDefaultEditor(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: ?*std.process.Environ.Map,
    repo_root: []const u8,
) BuildError![]u8 {
    const env = env_map orelse return error.NoEditorFound;
    const path_value = env.get("PATH") orelse return error.NoEditorFound;
    for ([_][]const u8{ "nvim", "vim", "vi" }) |name| {
        var directories = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
        while (directories.next()) |directory| {
            // Relative PATH entries use the same cwd as the foreground editor.
            const candidate = try std.fs.path.join(allocator, if (std.fs.path.isAbsolute(directory))
                &.{ directory, name }
            else
                &.{ repo_root, directory, name });
            var found = false;
            defer if (!found) allocator.free(candidate);
            const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
            if (stat.kind != .file) continue;
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
            found = true;
            return candidate;
        }
    }
    return error.NoEditorFound;
}

fn nonEmptyEnv(env_map: *std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env_map.get(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else null;
}

test "editor explicit commands take precedence without executable probing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("VISUAL", "missing-visual --flag");
    try env.put("EDITOR", "missing-editor");
    const target: Target = .{ .repo_root = "/repo", .path = "src/main.zig", .line = 42 };
    var configured: config.EditorConfig = .{};
    configured.argv[0] = "missing-config-editor";
    configured.argv[1] = "{path}";
    configured.argv_len = 2;
    var result = try build(std.testing.allocator, std.testing.io, configured, &env, target);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("missing-config-editor", result.argv[0]);

    var visual = try build(std.testing.allocator, std.testing.io, .{}, &env, target);
    defer visual.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), visual.argv.len);
    try std.testing.expectEqualStrings("missing-visual", visual.argv[0]);
    try std.testing.expectEqualStrings("--flag", visual.argv[1]);
    try std.testing.expectEqualStrings(target.path, visual.argv[2]);

    try env.put("VISUAL", " \t");
    var editor = try build(std.testing.allocator, std.testing.io, .{}, &env, target);
    defer editor.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), editor.argv.len);
    try std.testing.expectEqualStrings("missing-editor", editor.argv[0]);
    try std.testing.expectEqualStrings(target.path, editor.argv[1]);
}

test "editor discovery prefers nvim vim vi and skips unavailable executables" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "first", .default_dir);
    try tmp.dir.createDir(io, "bin space", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const second = try std.fs.path.join(allocator, &.{ root, "bin space" });
    defer allocator.free(second);
    const path = try std.fmt.allocPrint(allocator, "first:{s}", .{second});
    defer allocator.free(path);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", path);
    try env.put("VISUAL", " ");
    try env.put("EDITOR", "");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin space/nvim", .data = "" });
    for ([_][]const u8{ "first/vim", "first/vi" }) |file| {
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "", .flags = .{ .permissions = .executable_file } });
    }
    const nvim = try std.fs.path.join(allocator, &.{ second, "nvim" });
    defer allocator.free(nvim);
    const vim = try std.fs.path.join(allocator, &.{ root, "first/vim" });
    defer allocator.free(vim);
    const vi = try std.fs.path.join(allocator, &.{ root, "first/vi" });
    defer allocator.free(vi);
    const target: Target = .{ .repo_root = root, .path = "+file.txt", .line = 42 };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, environment: *std.process.Environ.Map, file: Target, expected: []const u8) !void {
            var result = try build(alloc, std.testing.io, .{}, environment, file);
            defer result.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 2), result.argv.len);
            try std.testing.expectEqualStrings(expected, result.argv[0]);
            try std.testing.expectEqualStrings("./+file.txt", result.argv[1]);
        }
    };
    try Check.run(allocator, &env, target, vim);
    try tmp.dir.setFilePermissions(io, "bin space/nvim", .executable_file, .{});
    try std.testing.checkAllAllocationFailures(allocator, Check.run, .{ &env, target, nvim });
    try tmp.dir.deleteFile(io, "bin space/nvim");
    try tmp.dir.createDir(io, "bin space/nvim", .default_dir);
    try Check.run(allocator, &env, target, vim);
    try tmp.dir.deleteFile(io, "first/vim");
    try Check.run(allocator, &env, target, vi);
    try tmp.dir.deleteFile(io, "first/vi");
    try std.testing.expectError(error.NoEditorFound, build(allocator, io, .{}, &env, target));
}

test "configured argv wins and expands placeholders" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "nvim";
    editor_config.argv[1] = "+{line}";
    editor_config.argv[2] = "{repo_root}/{path}:{column}";
    editor_config.argv_len = 3;

    var result = try build(std.testing.allocator, std.testing.io, editor_config, null, .{
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

    try std.testing.expectError(error.MissingPathPlaceholder, build(std.testing.allocator, std.testing.io, editor_config, null, .{
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

    try std.testing.expectError(error.UnknownPlaceholder, build(std.testing.allocator, std.testing.io, editor_config, null, .{
        .repo_root = "/repo",
        .path = "src/main.zig",
    }));
}

test "configured argv rejects empty command" {
    var editor_config: config.EditorConfig = .{};
    editor_config.argv[0] = "";
    editor_config.argv[1] = "{path}";
    editor_config.argv_len = 2;

    try std.testing.expectError(error.EmptyArgv, build(std.testing.allocator, std.testing.io, editor_config, null, .{
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
            var env = std.process.Environ.Map.init(std.testing.allocator);
            defer env.deinit();
            try env.put("VISUAL", "vi");
            var result = try build(allocator, std.testing.io, editor_config, &env, .{
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
            var result = try build(std.testing.allocator, std.testing.io, settings, &env, .{
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
