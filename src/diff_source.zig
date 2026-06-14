const std = @import("std");

const max_diff_bytes = 16 * 1024 * 1024;

/// User-selected source for the raw unified diff text.
///
/// Terminal mode can read all variants directly. Browser mode can later reuse
/// the same shape while swapping the backend behind it.
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

/// Concrete load request used by backends.
///
/// `source` answers "what diff should be read"; `repo_root` answers "where a
/// Git command should run". Raw text sources such as stdin and patch files can
/// leave `repo_root` null because they do not execute Git.
pub const LoadRequest = struct {
    source: SourceMode,
    repo_root: ?[]const u8 = null,

    pub fn requiresRepo(self: LoadRequest) bool {
        return sourceRequiresRepo(self.source);
    }
};

pub fn sourceRequiresRepo(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached, .range => true,
        .stdin, .patch_file => false,
    };
}

pub const ParseArgsError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidRange,
    TooManyInputs,
    ConflictingSourceMode,
};

pub const LoadError = error{
    ReadFailed,
    StreamTooLong,
    OutOfMemory,
    SpawnFailed,
    MissingRepoRoot,
};

pub const LoadResult = union(enum) {
    /// Allocated raw diff text. Caller owns and must call `deinit`.
    ok: []u8,
    /// Allocated error message from the backend. Caller owns and must call `deinit`.
    failed: []u8,
    /// Non-owned fallback error message, used when allocation itself fails.
    failed_static: []const u8,

    pub fn deinit(self: LoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bytes| allocator.free(bytes),
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

/// Minimal backend boundary for obtaining raw unified diff text.
///
/// It is intentionally one-method for now: Phase 1 only needs read-only diff
/// acquisition, while future browser/backend work can add another implementation
/// without wiring process execution through the app state.
pub const GitBackend = struct {
    ptr: *anyopaque,
    load_diff_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, LoadRequest) LoadError!LoadResult,

    pub fn loadDiff(self: GitBackend, allocator: std.mem.Allocator, io: std.Io, request: LoadRequest) LoadError!LoadResult {
        return self.load_diff_fn(self.ptr, allocator, io, request);
    }
};

pub const LocalGitCommandBackend = struct {
    pub fn backend(self: *LocalGitCommandBackend) GitBackend {
        return .{
            .ptr = self,
            .load_diff_fn = loadDiffErased,
        };
    }

    pub fn loadDiff(_: *LocalGitCommandBackend, allocator: std.mem.Allocator, io: std.Io, request: LoadRequest) LoadError!LoadResult {
        return switch (request.source) {
            .unstaged => loadGitDiff(allocator, io, request.repo_root orelse return error.MissingRepoRoot, &.{ "git", "diff", "--no-color", "--no-ext-diff" }),
            .cached => loadGitDiff(allocator, io, request.repo_root orelse return error.MissingRepoRoot, &.{ "git", "diff", "--cached", "--no-color", "--no-ext-diff" }),
            .range => |range| loadGitDiff(allocator, io, request.repo_root orelse return error.MissingRepoRoot, &.{ "git", "diff", "--no-color", "--no-ext-diff", range }),
            .patch_file => |path| .{ .ok = readPatchFile(allocator, io, path) catch |err| return mapReadError(err) },
            .stdin => .{ .ok = readStdin(allocator, io) catch |err| return mapReadError(err) },
        };
    }

    fn loadDiffErased(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: LoadRequest) LoadError!LoadResult {
        const self: *LocalGitCommandBackend = @ptrCast(@alignCast(ctx));
        return self.loadDiff(allocator, io, request);
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
            if (isOptionLikeValue(args[index])) return error.InvalidRange;
            try setSourceMode(&config, .{ .range = args[index] });
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            const value = arg["--range=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            if (isOptionLikeValue(value)) return error.InvalidRange;
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

fn isOptionLikeValue(value: []const u8) bool {
    return value.len > 0 and value[0] == '-';
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

pub fn cloneLoadRequest(allocator: std.mem.Allocator, request: LoadRequest) std.mem.Allocator.Error!LoadRequest {
    const source = try cloneSource(allocator, request.source);
    errdefer freeSource(allocator, source);

    return .{
        .source = source,
        .repo_root = if (request.repo_root) |repo_root| try allocator.dupe(u8, repo_root) else null,
    };
}

pub fn freeSource(allocator: std.mem.Allocator, source: SourceMode) void {
    switch (source) {
        .patch_file => |path| allocator.free(path),
        .range => |range| allocator.free(range),
        else => {},
    }
}

pub fn freeLoadRequest(allocator: std.mem.Allocator, request: LoadRequest) void {
    freeSource(allocator, request.source);
    if (request.repo_root) |repo_root| allocator.free(repo_root);
}

/// Convenience entry point for terminal mode. The explicit GitBackend interface
/// remains available for tests and future non-local backends.
pub fn load(allocator: std.mem.Allocator, io: std.Io, request: LoadRequest) LoadError!LoadResult {
    var local_backend: LocalGitCommandBackend = .{};
    return local_backend.backend().loadDiff(allocator, io, request);
}

fn loadGitDiff(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, argv: []const []const u8) LoadError!LoadResult {
    // Use structured argv and disable color/ext-diff so the parser sees stable
    // Git unified diff output, not user-configured pager formatting.
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
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
    // Prefer Git's stderr when available; it usually contains the actionable
    // reason, for example "not a git repository".
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

test "parseArgs rejects option-like range values" {
    const equals_form = [_][]const u8{ "gitframe", "--range=--output=/tmp/gitframe.diff" };
    try std.testing.expectError(error.InvalidRange, parseArgs(equals_form[0..]));

    const separate_value = [_][]const u8{ "gitframe", "--range", "--output=/tmp/gitframe.diff" };
    try std.testing.expectError(error.InvalidRange, parseArgs(separate_value[0..]));
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

test "LoadRequest identifies sources that require a repo root" {
    try std.testing.expect((LoadRequest{ .source = .unstaged }).requiresRepo());
    try std.testing.expect((LoadRequest{ .source = .cached }).requiresRepo());
    try std.testing.expect((LoadRequest{ .source = .{ .range = "main...HEAD" } }).requiresRepo());

    try std.testing.expect(!(LoadRequest{ .source = .stdin }).requiresRepo());
    try std.testing.expect(!(LoadRequest{ .source = .{ .patch_file = "change.diff" } }).requiresRepo());
}

test "cloneLoadRequest duplicates source payload and repo root" {
    const allocator = std.testing.allocator;
    const request = try cloneLoadRequest(allocator, .{
        .source = .{ .range = "main...HEAD" },
        .repo_root = "/repo",
    });
    defer freeLoadRequest(allocator, request);

    try std.testing.expect(request.source == .range);
    try std.testing.expectEqualStrings("main...HEAD", request.source.range);
    try std.testing.expectEqualStrings("/repo", request.repo_root.?);
}

test "LocalGitCommandBackend requires repo root for git sources" {
    var local_backend: LocalGitCommandBackend = .{};
    try std.testing.expectError(error.MissingRepoRoot, local_backend.loadDiff(std.testing.allocator, std.testing.io, .{
        .source = .unstaged,
        .repo_root = null,
    }));
}

test "LocalGitCommandBackend exposes backend interface" {
    var local_backend: LocalGitCommandBackend = .{};
    const backend = local_backend.backend();

    try std.testing.expect(backend.ptr == @as(*anyopaque, @ptrCast(&local_backend)));
}
