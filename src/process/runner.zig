const std = @import("std");

pub const Error = error{
    EmptyArgv,
    StreamTooLong,
    WriteFailed,
} || std.process.SpawnError || std.process.Child.WaitError || std.Io.File.MultiReader.UnendingError || std.Io.Timeout.Error || std.Io.File.Writer.Error;

pub const Options = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    stdin: []const u8 = &.{},
    stdout_limit: std.Io.Limit = .unlimited,
    stderr_limit: std.Io.Limit = .unlimited,
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Failure = union(enum) {
    empty_argv,
    spawn: anyerror,
    stdin: anyerror,
    capture: anyerror,
    wait: anyerror,

    pub fn errorName(self: Failure) []const u8 {
        return switch (self) {
            .empty_argv => "EmptyArgv",
            inline .spawn, .stdin, .capture, .wait => |err| @errorName(err),
        };
    }

    pub fn toError(self: Failure) Error {
        return switch (self) {
            .empty_argv => error.EmptyArgv,
            inline .spawn, .stdin, .capture, .wait => |err| @errorCast(err),
        };
    }
};

pub const DetailedResult = union(enum) {
    ok: Result,
    failed: Failure,
};

/// Run a child process with structured argv and captured stdout/stderr.
///
/// This is shared by Git commands and ExternalAction so process ownership,
/// stdin handling, output caps, and child cleanup stay in one place.
pub fn runWithStdin(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Result {
    const detailed = try runWithStdinDetailed(allocator, io, options);
    return switch (detailed) {
        .ok => |result| result,
        .failed => |failure| failure.toError(),
    };
}

/// Same process runner as `runWithStdin`, but preserves the failure phase.
///
/// External actions use this so UI can distinguish "could not start command"
/// from "command started, but runner IO/capture/wait failed".
pub fn runWithStdinDetailed(allocator: std.mem.Allocator, io: std.Io, options: Options) std.mem.Allocator.Error!DetailedResult {
    if (options.argv.len == 0) return .{ .failed = .empty_argv };

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = .{ .spawn = err } };
    var child_waited = false;
    defer if (!child_waited) child.kill(io);

    var write_buffer: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writerStreaming(io, &write_buffer);
    stdin_writer.interface.writeAll(options.stdin) catch |err| return .{ .failed = .{ .stdin = err } };
    stdin_writer.interface.flush() catch |err| return .{ .failed = .{ .stdin = err } };
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .none)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) return .{ .failed = .{ .capture = error.StreamTooLong } };
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) return .{ .failed = .{ .capture = error.StreamTooLong } };
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return .{ .failed = .{ .capture = e } },
    }

    multi_reader.checkAnyError() catch |err| return .{ .failed = .{ .capture = err } };

    const term = child.wait(io) catch |err| return .{ .failed = .{ .wait = err } };
    child_waited = true;
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .ok = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

test "runWithStdin captures stdout and stderr" {
    const argv = [_][]const u8{ "sh", "-c", "printf out; printf err >&2" };
    const result = try runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = &.{},
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runWithStdin writes stdin" {
    const argv = [_][]const u8{ "sh", "-c", "cat" };
    const result = try runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = "from stdin",
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("from stdin", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runWithStdin enforces output caps" {
    const argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    try std.testing.expectError(error.StreamTooLong, runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = &.{},
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    }));
}

test "runWithStdin rejects empty argv" {
    try std.testing.expectError(error.EmptyArgv, runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &.{},
    }));
}
