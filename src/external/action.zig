const std = @import("std");
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

pub const ExternalActionRequest = struct {
    id: ExternalActionId,
    argv: []const []const u8,
    stdin_json: []const u8,
    cwd: ?[]const u8 = null,

    pub fn clone(self: ExternalActionRequest, allocator: std.mem.Allocator) std.mem.Allocator.Error!OwnedExternalActionRequest {
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
        const cwd = if (self.cwd) |cwd| try allocator.dupe(u8, cwd) else null;
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
    cwd: ?[]u8 = null,

    pub fn deinit(self: *OwnedExternalActionRequest, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.stdin_json);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.* = .{
            .id = .custom,
            .argv = &.{},
            .stdin_json = &.{},
            .cwd = null,
        };
    }

    pub fn borrowed(self: *const OwnedExternalActionRequest) ExternalActionRequest {
        return .{
            .id = self.id,
            .argv = self.argv,
            .stdin_json = self.stdin_json,
            .cwd = self.cwd,
        };
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, request: ExternalActionRequest) std.mem.Allocator.Error!ExternalActionResult {
    const detailed = try process_runner.runWithStdinDetailed(allocator, io, .{
        .argv = request.argv,
        .stdin = request.stdin_json,
        .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
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

fn resultForRunFailure(allocator: std.mem.Allocator, failure: process_runner.Failure) std.mem.Allocator.Error!ExternalActionResult {
    const message = try std.fmt.allocPrint(allocator, "external action failed: {s}", .{failure.errorName()});
    const output: CommandOutput = .{ .message = message };
    return switch (failure) {
        .empty_argv, .spawn => .{ .spawn_failed = output },
        .stdin, .capture, .wait => .{ .runner_failed = output },
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
