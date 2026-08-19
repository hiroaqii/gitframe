//! Mechanical execution boundary for local Git commands.
//!
//! Repository domains decide what to run and how to interpret the result.
//! This leaf only binds a borrowed directory descriptor to an owned,
//! repository-selector-free environment and translates runner failures.

const std = @import("std");
const process_runner = @import("../process/runner.zig");

pub const Error = error{
    StreamTooLong,
    OutOfMemory,
    SpawnFailed,
};

/// Owned replacement environment for one logical local Git request.
///
/// Construction always copies an explicit snapshot. Removing the complete
/// `GIT_*` family prevents inherited selectors from competing with the
/// caller's directory descriptor.
pub const LocalGitEnvironment = struct {
    map: std.process.Environ.Map,

    pub fn initFromParent(
        allocator: std.mem.Allocator,
        parent: ?*const std.process.Environ.Map,
    ) Error!LocalGitEnvironment {
        var map = if (parent) |snapshot|
            snapshot.clone(allocator) catch return error.OutOfMemory
        else
            std.process.Environ.Map.init(allocator);
        errdefer map.deinit();
        removeGitSelectors(&map);
        return .{ .map = map };
    }

    pub fn borrow(self: *const LocalGitEnvironment) *const std.process.Environ.Map {
        return &self.map;
    }

    pub fn deinit(self: *LocalGitEnvironment) void {
        self.map.deinit();
        self.* = undefined;
    }
};

/// Borrowed authority for one synchronous repository command.
pub const DirectoryContext = struct {
    cwd: std.Io.Dir,
    environment: *const LocalGitEnvironment,
};

pub const CapturedOptions = struct {
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
};

pub const BoundedCaptureResult = process_runner.BoundedCaptureResult;

pub const StdinOptions = struct {
    argv: []const []const u8,
    stdin: []const u8,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
};

pub const NonRepositoryCwd = union(enum) {
    inherit,
    dir: std.Io.Dir,
};

pub fn runCaptured(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: DirectoryContext,
    options: CapturedOptions,
) Error!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = options.argv,
        .cwd = .{ .dir = context.cwd },
        .environ_map = context.environment.borrow(),
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    }) catch |err| return fromRunnerError(err);
}

/// Preserve stdout/stderr overflow as separate terminals while retaining the
/// shared runner's child and buffer ownership.
pub fn runCapturedBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: DirectoryContext,
    options: CapturedOptions,
) std.mem.Allocator.Error!BoundedCaptureResult {
    return process_runner.runCapturedBounded(allocator, io, .{
        .argv = options.argv,
        .cwd = .{ .dir = context.cwd },
        .environ_map = context.environment.borrow(),
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    });
}

pub fn runWithStdin(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: DirectoryContext,
    options: StdinOptions,
) Error!process_runner.Result {
    return process_runner.runWithStdin(allocator, io, .{
        .argv = options.argv,
        .cwd = .{ .dir = context.cwd },
        .environ_map = context.environment.borrow(),
        .stdin = options.stdin,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    }) catch |err| return fromRunnerError(err);
}

pub fn runWithStdinBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: DirectoryContext,
    options: StdinOptions,
) std.mem.Allocator.Error!BoundedCaptureResult {
    return process_runner.runWithStdinBounded(allocator, io, .{
        .argv = options.argv,
        .cwd = .{ .dir = context.cwd },
        .environ_map = context.environment.borrow(),
        .stdin = options.stdin,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    });
}

/// Captured helper for an explicitly non-repository command such as external
/// file-pair `git diff --no-index`. Repository paths are intentionally absent.
pub fn runNonRepositoryCaptured(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: NonRepositoryCwd,
    environment: *const LocalGitEnvironment,
    options: CapturedOptions,
) Error!process_runner.Result {
    return process_runner.runCaptured(allocator, io, .{
        .argv = options.argv,
        .cwd = switch (cwd) {
            .inherit => .inherit,
            .dir => |dir| .{ .dir = dir },
        },
        .environ_map = environment.borrow(),
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    }) catch |err| return fromRunnerError(err);
}

/// Translate runner mechanics without importing domain result vocabulary.
pub fn fromRunnerError(err: process_runner.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.SpawnFailed,
    };
}

fn removeGitSelectors(map: *std.process.Environ.Map) void {
    var index: usize = 0;
    while (index < map.keys().len) {
        const key = map.keys()[index];
        if (key.len >= "GIT_".len and std.ascii.eqlIgnoreCase(key[0.."GIT_".len], "GIT_")) {
            _ = map.swapRemove(key);
        } else {
            index += 1;
        }
    }
}

test "controlled Git environment removes inherited repository authority" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("HOME", "/home/test");
    try parent.put("gIt_Custom_Selector", "redirect");

    const git_keys = [_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_BARE",
        "GIT_SHALLOW_FILE",
        "GIT_REPLACE_REF_BASE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    };
    for (git_keys) |key| try parent.put(key, "redirect");

    var environment = try LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();

    try std.testing.expectEqualStrings("/home/test", environment.borrow().get("HOME").?);
    try std.testing.expect(environment.borrow().get("gIt_Custom_Selector") == null);
    for (git_keys) |key| try std.testing.expect(environment.borrow().get(key) == null);
    try std.testing.expectEqualStrings("redirect", parent.get("GIT_DIR").?);
}

test "bounded Git adapter preserves stdout and stderr overflow terminals" {
    var environment = try LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: DirectoryContext = .{ .cwd = std.Io.Dir.cwd(), .environment = &environment };
    const stdout_argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    var stdout = try runCapturedBounded(std.testing.allocator, std.testing.io, context, .{
        .argv = &stdout_argv,
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    });
    defer stdout.deinit(std.testing.allocator);
    try std.testing.expect(stdout == .stdout_limit_exceeded);

    const stderr_argv = [_][]const u8{ "sh", "-c", "printf abcdef >&2" };
    var stderr = try runCapturedBounded(std.testing.allocator, std.testing.io, context, .{
        .argv = &stderr_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(3),
    });
    defer stderr.deinit(std.testing.allocator);
    try std.testing.expect(stderr == .stderr_limit_exceeded);
}
