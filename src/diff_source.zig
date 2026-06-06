const std = @import("std");

const max_diff_bytes = 16 * 1024 * 1024;

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

pub const ParseArgsError = error{
    UnknownOption,
    MissingOptionValue,
    TooManyInputs,
    ConflictingSourceMode,
};

pub const LoadError = error{
    ReadFailed,
    StreamTooLong,
    OutOfMemory,
    SpawnFailed,
};

pub const LoadResult = union(enum) {
    ok: []u8,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: LoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const GitBackend = struct {
    ptr: *anyopaque,
    load_diff_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, SourceMode) LoadError!LoadResult,

    pub fn loadDiff(self: GitBackend, allocator: std.mem.Allocator, io: std.Io, source: SourceMode) LoadError!LoadResult {
        return self.load_diff_fn(self.ptr, allocator, io, source);
    }
};

pub const LocalGitCommandBackend = struct {
    pub fn backend(self: *LocalGitCommandBackend) GitBackend {
        return .{
            .ptr = self,
            .load_diff_fn = loadDiffErased,
        };
    }

    pub fn loadDiff(_: *LocalGitCommandBackend, allocator: std.mem.Allocator, io: std.Io, source: SourceMode) LoadError!LoadResult {
        return switch (source) {
            .unstaged => loadGitDiff(allocator, io, &.{ "git", "diff", "--no-color", "--no-ext-diff" }),
            .cached => loadGitDiff(allocator, io, &.{ "git", "diff", "--cached", "--no-color", "--no-ext-diff" }),
            .range => |range| loadGitDiff(allocator, io, &.{ "git", "diff", "--no-color", "--no-ext-diff", range }),
            .patch_file => |path| .{ .ok = readPatchFile(allocator, io, path) catch |err| return mapReadError(err) },
            .stdin => .{ .ok = readStdin(allocator, io) catch |err| return mapReadError(err) },
        };
    }

    fn loadDiffErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: SourceMode) LoadError!LoadResult {
        const self: *LocalGitCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadDiff(allocator, io, source);
    }
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

pub fn cloneSource(allocator: std.mem.Allocator, source: SourceMode) std.mem.Allocator.Error!SourceMode {
    return switch (source) {
        .unstaged => .unstaged,
        .cached => .cached,
        .stdin => .stdin,
        .patch_file => |path| .{ .patch_file = try allocator.dupe(u8, path) },
        .range => |range| .{ .range = try allocator.dupe(u8, range) },
    };
}

pub fn freeSource(allocator: std.mem.Allocator, source: SourceMode) void {
    switch (source) {
        .patch_file => |path| allocator.free(path),
        .range => |range| allocator.free(range),
        else => {},
    }
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, source: SourceMode) LoadError!LoadResult {
    var local_backend: LocalGitCommandBackend = .{};
    return local_backend.backend().loadDiff(allocator, io, source);
}

fn loadGitDiff(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) LoadError!LoadResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_diff_bytes),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };

    switch (result.term) {
        .exited => |code| if (code == 0) {
            allocator.free(result.stderr);
            return .{ .ok = result.stdout };
        },
        else => {},
    }

    allocator.free(result.stdout);
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);

    return .{ .failed = std.fmt.allocPrint(allocator, "git diff failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn readPatchFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_diff_bytes));
}

fn readStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    return try reader.interface.allocRemaining(allocator, .limited(max_diff_bytes));
}

fn mapReadError(err: anyerror) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.ReadFailed,
    };
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

test "cloneSource duplicates payload source modes" {
    const allocator = std.testing.allocator;
    const source = try cloneSource(allocator, .{ .range = "main...HEAD" });
    defer freeSource(allocator, source);

    try std.testing.expect(source == .range);
    try std.testing.expectEqualStrings("main...HEAD", source.range);
}

test "LocalGitCommandBackend exposes backend interface" {
    var local_backend: LocalGitCommandBackend = .{};
    const backend = local_backend.backend();

    try std.testing.expect(backend.ptr == @as(*anyopaque, @ptrCast(&local_backend)));
}
