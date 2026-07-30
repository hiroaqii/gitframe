const std = @import("std");

pub const Error = error{
    EmptyArgv,
    StreamTooLong,
    WriteFailed,
} || std.process.SpawnError || std.process.Child.WaitError || std.Io.File.MultiReader.UnendingError || std.Io.Timeout.Error || std.Io.File.Writer.Error;

pub const Options = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    /// Complete child environment. Non-null replaces, rather than augments,
    /// the inherited process environment.
    environ_map: ?*const std.process.Environ.Map = null,
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

pub const StdinFailure = struct {
    err: anyerror,
    result: Result,

    pub fn takeResult(self: *StdinFailure) Result {
        const result = self.result;
        self.result.stdout = &.{};
        self.result.stderr = &.{};
        return result;
    }
};

pub const Failure = union(enum) {
    empty_argv,
    spawn: anyerror,
    stdin: StdinFailure,
    capture: anyerror,
    wait: anyerror,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stdin => |*failure| failure.result.deinit(allocator),
            else => {},
        }
        self.* = .empty_argv;
    }

    pub fn errorName(self: Failure) []const u8 {
        return switch (self) {
            .empty_argv => "EmptyArgv",
            .stdin => |failure| @errorName(failure.err),
            inline .spawn, .capture, .wait => |err| @errorName(err),
        };
    }

    pub fn toError(self: Failure) Error {
        return switch (self) {
            .empty_argv => error.EmptyArgv,
            .stdin => |failure| @errorCast(failure.err),
            inline .spawn, .capture, .wait => |err| @errorCast(err),
        };
    }
};

pub const DetailedResult = union(enum) {
    ok: Result,
    failed: Failure,

    pub fn deinit(self: *DetailedResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |result| result.deinit(allocator),
            .failed => |*failure| failure.deinit(allocator),
        }
        self.* = .{ .failed = .empty_argv };
    }
};

const FailurePhase = enum {
    capture,
    wait,
    stdin,
};

fn primaryFailurePhase(capture_error: ?anyerror, wait_error: ?anyerror, stdin_error: ?anyerror) ?FailurePhase {
    if (capture_error != null) return .capture;
    if (wait_error != null) return .wait;
    if (stdin_error != null) return .stdin;
    return null;
}

fn failureWithoutResult(capture_error: ?anyerror, wait_error: ?anyerror, stdin_error: ?anyerror) Failure {
    return switch (primaryFailurePhase(capture_error, wait_error, stdin_error).?) {
        .capture => .{ .capture = capture_error.? },
        .wait => .{ .wait = wait_error.? },
        .stdin => unreachable,
    };
}

/// Run a child process with structured argv and captured stdout/stderr, without stdin.
pub fn runCaptured(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Result {
    var captured_options = options;
    captured_options.stdin = &.{};
    return runWithStdin(allocator, io, captured_options);
}

/// Run a child process with structured argv and captured stdout/stderr.
///
/// This is shared by Git commands and ExternalAction so process ownership,
/// stdin handling, output caps, and child cleanup stay in one place.
pub fn runWithStdin(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Result {
    const detailed = try runWithStdinDetailed(allocator, io, options);
    return resultFromDetailed(allocator, detailed);
}

fn resultFromDetailed(allocator: std.mem.Allocator, detailed: DetailedResult) Error!Result {
    return switch (detailed) {
        .ok => |result| result,
        .failed => |failure_value| {
            var failure = failure_value;
            defer failure.deinit(allocator);
            return failure.toError();
        },
    };
}

/// Same process runner as `runWithStdin`, but preserves the failure phase.
///
/// Consumers which need failure evidence use this to distinguish "could not
/// start command" from "command started, but runner IO/capture/wait failed".
pub fn runWithStdinDetailed(allocator: std.mem.Allocator, io: std.Io, options: Options) std.mem.Allocator.Error!DetailedResult {
    if (options.argv.len == 0) return .{ .failed = .empty_argv };

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = .{ .spawn = err } };
    var child_waited = false;
    var stdin_future: ?std.Io.Future(?anyerror) = null;
    defer {
        if (!child_waited) child.kill(io);
        if (stdin_future) |*future| _ = future.cancel(io);
    }

    const stdin_file = child.stdin.?;
    child.stdin = null;
    var stdin_error: ?anyerror = null;
    if (options.stdin.len == 0) {
        stdin_file.close(io);
    } else {
        stdin_future = io.concurrent(pumpStdin, .{ stdin_file, io, options.stdin }) catch |err| start_failed: {
            stdin_file.close(io);
            stdin_error = err;
            break :start_failed null;
        };
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var capture_error: ?anyerror = null;
    while (multi_reader.fill(64, .none)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) {
                capture_error = error.StreamTooLong;
                break;
            }
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) {
                capture_error = error.StreamTooLong;
                break;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| capture_error = e,
    }

    if (capture_error == null) {
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
        };
    }
    if (capture_error) |err| {
        return .{ .failed = failureWithoutResult(err, null, stdin_error) };
    }

    if (stdin_future) |*future| {
        stdin_error = future.await(io);
        stdin_future = null;
    }

    const term = child.wait(io) catch |err| {
        return .{ .failed = failureWithoutResult(null, err, stdin_error) };
    };
    child_waited = true;
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    const result: Result = .{ .term = term, .stdout = stdout, .stderr = stderr };
    if (stdin_error) |err| {
        std.debug.assert(primaryFailurePhase(null, null, err).? == .stdin);
        return .{ .failed = .{ .stdin = .{ .err = err, .result = result } } };
    }
    return .{ .ok = result };
}

fn pumpStdin(file: std.Io.File, io: std.Io, stdin: []const u8) ?anyerror {
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &write_buffer);
    writer.interface.writeAll(stdin) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;
    return null;
}

const TestWatchResult = union(enum) {
    runner: std.mem.Allocator.Error!DetailedResult,
    timeout: std.Io.Cancelable!void,
};

fn testWatchdogSleep(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(5), .awake);
}

fn deinitTestWatchResult(allocator: std.mem.Allocator, result: TestWatchResult) void {
    switch (result) {
        .runner => |runner_result| {
            var detailed = runner_result catch return;
            detailed.deinit(allocator);
        },
        .timeout => {},
    }
}

fn drainTestWatchSelect(allocator: std.mem.Allocator, select: *std.Io.Select(TestWatchResult)) void {
    while (select.cancel()) |result| deinitTestWatchResult(allocator, result);
}

fn runDetailedWithTestWatchdog(allocator: std.mem.Allocator, io: std.Io, options: Options) !DetailedResult {
    var result_buffer: [2]TestWatchResult = undefined;
    var select: std.Io.Select(TestWatchResult) = .init(io, &result_buffer);
    defer drainTestWatchSelect(allocator, &select);

    try select.concurrent(.runner, runWithStdinDetailed, .{ allocator, io, options });
    try select.concurrent(.timeout, testWatchdogSleep, .{io});

    return switch (try select.await()) {
        .runner => |runner_result| try runner_result,
        .timeout => |timeout_result| {
            try timeout_result;
            return error.TestTimedOut;
        },
    };
}

test "concurrent stdin preserves diagnostics after early child exit" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{ "sh", "-c", "exec 0<&-; printf retained-diagnostic >&2; exit 7" };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(1024),
    });
    defer detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .stdin => |stdin_failure| {
                try std.testing.expectEqualStrings("", stdin_failure.result.stdout);
                try std.testing.expectEqualStrings("retained-diagnostic", stdin_failure.result.stderr);
                try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, stdin_failure.result.term);
            },
            else => return error.ExpectedStdinFailure,
        },
        .ok => return error.ExpectedStdinFailure,
    }
}

test "concurrent stdin drains large bidirectional IO without deadlock" {
    const stdin = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const output_bytes = 96 * 1024;
    const argv = [_][]const u8{
        "sh",
        "-c",
        "yes stdout | head -c 98304; yes stderr | head -c 98304 >&2; cat",
    };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer detailed.deinit(std.testing.allocator);

    const result = switch (detailed) {
        .ok => |result| result,
        .failed => return error.ExpectedSuccessfulBidirectionalRun,
    };
    try std.testing.expectEqual(output_bytes + stdin.len, result.stdout.len);
    try std.testing.expectEqual(output_bytes, result.stderr.len);
    try std.testing.expectEqualStrings(stdin, result.stdout[result.stdout.len - stdin.len ..]);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "concurrent stdin capture failure outranks simultaneous writer failure" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{
        "sh",
        "-c",
        "exec 0<&-; yes overflow | head -c 131072; printf ignored-diagnostic >&2; exit 9",
    };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .capture => |err| try std.testing.expectEqual(error.StreamTooLong, err),
            else => return error.ExpectedCaptureFailure,
        },
        .ok => return error.ExpectedCaptureFailure,
    }
}

test "concurrent stdin arbitration orders capture wait and writer failures" {
    try std.testing.expectEqual(
        FailurePhase.capture,
        primaryFailurePhase(error.StreamTooLong, error.AccessDenied, error.WriteFailed).?,
    );
    try std.testing.expectEqual(
        FailurePhase.wait,
        primaryFailurePhase(null, error.AccessDenied, error.WriteFailed).?,
    );
    try std.testing.expectEqual(
        FailurePhase.capture,
        primaryFailurePhase(error.StreamTooLong, null, error.ConcurrencyUnavailable).?,
    );
    try std.testing.expectEqual(
        FailurePhase.stdin,
        primaryFailurePhase(null, null, error.ConcurrencyUnavailable).?,
    );
}

test "concurrent stdin compatibility wrapper releases failure evidence" {
    const stdout = try std.testing.allocator.dupe(u8, "out");
    const stderr = std.testing.allocator.dupe(u8, "diagnostic") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };

    try std.testing.expectError(error.WriteFailed, resultFromDetailed(std.testing.allocator, .{
        .failed = .{ .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 7 },
                .stdout = stdout,
                .stderr = stderr,
            },
        } },
    }));
}

test "runCaptured captures stdout and stderr" {
    const argv = [_][]const u8{ "sh", "-c", "printf out; printf err >&2" };
    const result = try runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runCaptured forwards explicit environment map" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GITFRAME_RUNNER_SENTINEL", "explicit");

    const argv = [_][]const u8{ "sh", "-c", "printf %s \"$GITFRAME_RUNNER_SENTINEL\"" };
    const result = try runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .environ_map = &env,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("explicit", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runCaptured enforces output caps" {
    const argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    try std.testing.expectError(error.StreamTooLong, runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    }));
}

test "runCaptured rejects empty argv" {
    try std.testing.expectError(error.EmptyArgv, runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &.{},
    }));
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
