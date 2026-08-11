const std = @import("std");
const builtin = @import("builtin");
const process_runner = @import("../process/runner.zig");

pub const stdout_limit = 1024 * 1024;
pub const stderr_limit = 1024 * 1024;

pub const ExternalActionId = enum {
    export_context,
    custom,
};

pub const CommandOutput = struct {
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    term: ?std.process.Child.Term = null,
    message: []u8 = &.{},

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
        if (self.message.len > 0) allocator.free(self.message);
        self.* = .{};
    }
};

pub const ExternalActionResult = union(enum) {
    ok: CommandOutput,
    failed: CommandOutput,
    spawn_failed: CommandOutput,
    runner_failed: CommandOutput,

    pub fn deinit(self: *ExternalActionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*output| output.deinit(allocator),
        }
        self.* = .{ .ok = .{} };
    }
};

pub const ExternalActionCwd = union(enum) {
    inherit,
    path: []const u8,
    dir: std.Io.Dir,
};

pub const ExternalActionCloneError = std.mem.Allocator.Error || error{
    ExternalActionCwdUnsupported,
    ExternalActionInvalidCwd,
    ExternalActionProcessFdQuotaExceeded,
    ExternalActionSystemFdQuotaExceeded,
    ExternalActionDuplicateCwdFailed,
};

const CwdOperations = struct {
    context: ?*anyopaque = null,
    duplicate: *const fn (?*anyopaque, std.posix.fd_t) ExternalActionCloneError!std.posix.fd_t = duplicateCwd,
    close: *const fn (?*anyopaque, std.posix.fd_t) void = closeCwd,
};

const OwnedExternalActionDir = struct {
    dir: std.Io.Dir,
    close_context: ?*anyopaque,
    close_fn: *const fn (?*anyopaque, std.posix.fd_t) void,

    fn deinit(self: *OwnedExternalActionDir) void {
        self.close_fn(self.close_context, self.dir.handle);
        self.* = undefined;
    }
};

pub const OwnedExternalActionCwd = union(enum) {
    inherit,
    path: []u8,
    dir: OwnedExternalActionDir,

    fn deinit(self: *OwnedExternalActionCwd, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .inherit => {},
            .path => |path| allocator.free(path),
            .dir => |*dir| dir.deinit(),
        }
        self.* = .inherit;
    }

    fn borrowed(self: *const OwnedExternalActionCwd) ExternalActionCwd {
        return switch (self.*) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
            .dir => |dir| .{ .dir = dir.dir },
        };
    }
};

pub const ExternalActionRequest = struct {
    id: ExternalActionId,
    argv: []const []const u8,
    stdin_json: []const u8,
    cwd: ExternalActionCwd = .inherit,

    pub fn clone(self: ExternalActionRequest, allocator: std.mem.Allocator) ExternalActionCloneError!OwnedExternalActionRequest {
        return self.cloneWithCwdOperations(allocator, .{});
    }

    fn cloneWithCwdOperations(
        self: ExternalActionRequest,
        allocator: std.mem.Allocator,
        operations: CwdOperations,
    ) ExternalActionCloneError!OwnedExternalActionRequest {
        var cwd = try cloneCwd(allocator, self.cwd, operations);
        errdefer cwd.deinit(allocator);

        var argv = try allocator.alloc([]u8, self.argv.len);
        errdefer allocator.free(argv);

        var owned_count: usize = 0;
        errdefer {
            for (argv[0..owned_count]) |arg| allocator.free(arg);
        }

        for (self.argv, 0..) |arg, i| {
            argv[i] = try allocator.dupe(u8, arg);
            owned_count += 1;
        }

        const stdin_json = try allocator.dupe(u8, self.stdin_json);
        errdefer allocator.free(stdin_json);
        return .{
            .id = self.id,
            .argv = argv,
            .stdin_json = stdin_json,
            .cwd = cwd,
        };
    }
};

pub const OwnedExternalActionRequest = struct {
    id: ExternalActionId,
    argv: [][]u8,
    stdin_json: []u8,
    cwd: OwnedExternalActionCwd = .inherit,

    pub fn deinit(self: *OwnedExternalActionRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.stdin_json);
        self.cwd.deinit(allocator);
        self.* = .{
            .id = .custom,
            .argv = &.{},
            .stdin_json = &.{},
            .cwd = .inherit,
        };
    }

    pub fn borrowed(self: *const OwnedExternalActionRequest) ExternalActionRequest {
        return .{
            .id = self.id,
            .argv = self.argv,
            .stdin_json = self.stdin_json,
            .cwd = self.cwd.borrowed(),
        };
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, request: ExternalActionRequest) std.mem.Allocator.Error!ExternalActionResult {
    const detailed = try process_runner.runWithStdinDetailed(allocator, io, .{
        .argv = request.argv,
        .stdin = request.stdin_json,
        .cwd = switch (request.cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
            .dir => |dir| .{ .dir = dir },
        },
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_limit),
    });

    const process_result = switch (detailed) {
        .ok => |result| result,
        .failed => |failure| return resultForRunFailure(allocator, failure),
    };
    errdefer process_result.deinit(allocator);

    const output: CommandOutput = .{
        .stdout = process_result.stdout,
        .stderr = process_result.stderr,
        .term = process_result.term,
    };

    return switch (process_result.term) {
        .exited => |code| if (code == 0) .{ .ok = output } else .{ .failed = output },
        else => .{ .failed = output },
    };
}

fn cloneCwd(
    allocator: std.mem.Allocator,
    cwd: ExternalActionCwd,
    operations: CwdOperations,
) ExternalActionCloneError!OwnedExternalActionCwd {
    return switch (cwd) {
        .inherit => .inherit,
        .path => |path| .{ .path = try allocator.dupe(u8, path) },
        .dir => |dir| .{ .dir = .{
            .dir = .{ .handle = try operations.duplicate(operations.context, dir.handle) },
            .close_context = operations.context,
            .close_fn = operations.close,
        } },
    };
}

fn duplicateCwd(_: ?*anyopaque, handle: std.posix.fd_t) ExternalActionCloneError!std.posix.fd_t {
    return switch (builtin.os.tag) {
        .linux, .macos => duplicateCwdSupported(handle),
        else => error.ExternalActionCwdUnsupported,
    };
}

fn duplicateCwdSupported(handle: std.posix.fd_t) ExternalActionCloneError!std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.fcntl(handle, std.posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.ExternalActionInvalidCwd,
            .MFILE => return error.ExternalActionProcessFdQuotaExceeded,
            .NFILE => return error.ExternalActionSystemFdQuotaExceeded,
            else => return error.ExternalActionDuplicateCwdFailed,
        }
    }
}

fn closeCwd(_: ?*anyopaque, handle: std.posix.fd_t) void {
    _ = std.posix.system.close(handle);
}

fn resultForRunFailure(allocator: std.mem.Allocator, failure_value: process_runner.Failure) std.mem.Allocator.Error!ExternalActionResult {
    var failure = failure_value;
    defer failure.deinit(allocator);

    const message = try std.fmt.allocPrint(allocator, "external action failed: {s}", .{failure.errorName()});
    const output: CommandOutput = switch (failure) {
        .stdin => |*stdin_failure| output: {
            const result = stdin_failure.takeResult();
            break :output .{
                .stdout = result.stdout,
                .stderr = result.stderr,
                .term = result.term,
                .message = message,
            };
        },
        else => .{ .message = message },
    };
    return switch (failure) {
        .empty_argv, .spawn => .{ .spawn_failed = output },
        .stdin_start, .stdin, .capture, .wait => .{ .runner_failed = output },
    };
}

test "ExternalActionRequest clone owns argv and stdin" {
    const raw_argv = [_][]const u8{ "cat", "--flag" };
    const request: ExternalActionRequest = .{
        .id = .custom,
        .argv = &raw_argv,
        .stdin_json = "{\"path\":\"src/app.zig\"}",
    };

    var owned = try request.clone(std.testing.allocator);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(ExternalActionId.custom, owned.id);
    try std.testing.expectEqual(@as(usize, 2), owned.argv.len);
    try std.testing.expectEqualStrings("cat", owned.argv[0]);
    try std.testing.expectEqualStrings("--flag", owned.argv[1]);
    try std.testing.expectEqualStrings("{\"path\":\"src/app.zig\"}", owned.stdin_json);

    try std.testing.expect(@intFromPtr(owned.argv[0].ptr) != @intFromPtr(raw_argv[0].ptr));
    try std.testing.expect(@intFromPtr(owned.stdin_json.ptr) != @intFromPtr(request.stdin_json.ptr));
}

test "ExternalActionRequest clone owns descriptor cwd" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TrackingOperations = struct {
        duplicate_count: usize = 0,
        close_count: usize = 0,
        last_duplicate: ?std.posix.fd_t = null,

        fn duplicate(context: ?*anyopaque, handle: std.posix.fd_t) ExternalActionCloneError!std.posix.fd_t {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const duplicated = try duplicateCwd(null, handle);
            self.duplicate_count += 1;
            self.last_duplicate = duplicated;
            return duplicated;
        }

        fn close(context: ?*anyopaque, handle: std.posix.fd_t) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.close_count += 1;
            closeCwd(null, handle);
        }

        fn operations(self: *@This()) CwdOperations {
            return .{
                .context = self,
                .duplicate = duplicate,
                .close = close,
            };
        }
    };

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "physical", .default_dir);
    const physical_path = try tmp.dir.realPathFileAlloc(io, "physical", allocator);
    defer allocator.free(physical_path);

    var caller_dir = try std.Io.Dir.openDirAbsolute(io, physical_path, .{});
    const argv = [_][]const u8{ "sh", "-c", "printf descriptor > descriptor-marker" };
    const request: ExternalActionRequest = .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = "{}",
        .cwd = .{ .dir = caller_dir },
    };

    var completed_tracking: TrackingOperations = .{};
    var owned = try request.cloneWithCwdOperations(allocator, completed_tracking.operations());
    try std.testing.expectEqual(@as(usize, 1), completed_tracking.duplicate_count);
    caller_dir.close(io);

    var result = try run(allocator, io, owned.borrowed());
    defer result.deinit(allocator);
    try std.testing.expect(result == .ok);
    try tmp.dir.access(io, "physical/descriptor-marker", .{});

    owned.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), completed_tracking.close_count);

    var partial_tracking: TrackingOperations = .{};
    var partial_caller = try std.Io.Dir.openDirAbsolute(io, physical_path, .{});
    defer partial_caller.close(io);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        (ExternalActionRequest{
            .id = .custom,
            .argv = &argv,
            .stdin_json = "{}",
            .cwd = .{ .dir = partial_caller },
        }).cloneWithCwdOperations(failing.allocator(), partial_tracking.operations()),
    );
    try std.testing.expectEqual(@as(usize, 1), partial_tracking.duplicate_count);
    try std.testing.expectEqual(@as(usize, 1), partial_tracking.close_count);
    try std.testing.expect(partial_tracking.last_duplicate != null);
}

test "ExternalAction run maps zero exit to ok" {
    const argv = [_][]const u8{ "sh", "-c", "printf ok" };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = "{\"ignored\":true}",
    });
    defer result.deinit(std.testing.allocator);

    const output = result.ok;
    try std.testing.expectEqualStrings("ok", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term.?);
}

test "ExternalAction run maps non-zero exit to failed" {
    const argv = [_][]const u8{ "sh", "-c", "printf bad >&2; exit 7" };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    const output = result.failed;
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqualStrings("bad", output.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, output.term.?);
}

test "ExternalAction run maps missing executable to spawn_failed" {
    const argv = [_][]const u8{"__gitframe_missing_external_action_command__"};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .spawn_failed);
    try std.testing.expect(std.mem.indexOf(u8, result.spawn_failed.message, "FileNotFound") != null);
}

test "ExternalAction run maps empty argv to spawn_failed" {
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &.{},
        .stdin_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .spawn_failed);
    try std.testing.expect(std.mem.indexOf(u8, result.spawn_failed.message, "EmptyArgv") != null);
}

test "ExternalAction cap overflow maps to runner_failed" {
    const argv = [_][]const u8{ "sh", "-c", "yes x" };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .runner_failed);
    try std.testing.expect(std.mem.indexOf(u8, result.runner_failed.message, "StreamTooLong") != null);
}

test "concurrent stdin ExternalAction preserves early exit diagnostics" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{ "sh", "-c", "exec 0<&-; printf external-diagnostic >&2; exit 7" };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .id = .custom,
        .argv = &argv,
        .stdin_json = stdin,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .runner_failed);
    try std.testing.expectEqualStrings("", result.runner_failed.stdout);
    try std.testing.expectEqualStrings("external-diagnostic", result.runner_failed.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, result.runner_failed.term.?);
    try std.testing.expect(std.mem.indexOf(u8, result.runner_failed.message, "external action failed:") != null);
}

test "concurrent stdin ExternalAction keeps writer failure when child exits zero" {
    const stdout = try std.testing.allocator.dupe(u8, "partial-output");
    const stderr = std.testing.allocator.dupe(u8, "partial-diagnostic") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };

    var result = try resultForRunFailure(std.testing.allocator, .{
        .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 0 },
                .stdout = stdout,
                .stderr = stderr,
            },
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .runner_failed);
    try std.testing.expectEqualStrings("partial-output", result.runner_failed.stdout);
    try std.testing.expectEqualStrings("partial-diagnostic", result.runner_failed.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.runner_failed.term.?);
    try std.testing.expect(std.mem.indexOf(u8, result.runner_failed.message, "WriteFailed") != null);
}

test "concurrent stdin ExternalAction releases evidence when message allocation fails" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_allocator.allocator();
    const stdout = try allocator.dupe(u8, "out");
    const stderr = try allocator.dupe(u8, "diagnostic");

    try std.testing.expectError(error.OutOfMemory, resultForRunFailure(allocator, .{
        .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 7 },
                .stdout = stdout,
                .stderr = stderr,
            },
        },
    }));
}

test "stdin admission ExternalAction classifies concurrency start failure as runner failure" {
    var result = try resultForRunFailure(std.testing.allocator, .{
        .stdin_start = error.ConcurrencyUnavailable,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .runner_failed);
    try std.testing.expectEqualStrings("", result.runner_failed.stdout);
    try std.testing.expectEqualStrings("", result.runner_failed.stderr);
    try std.testing.expect(result.runner_failed.term == null);
    try std.testing.expect(std.mem.indexOf(u8, result.runner_failed.message, "ConcurrencyUnavailable") != null);
}
