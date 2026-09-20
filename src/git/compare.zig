//! Compare caller policy.
//!
//! This module selects display refs for Compare. It owns no object resolution,
//! merge-base, ahead, or materialization semantics; those live in
//! `git/commit_diff.zig` and receive explicit inputs.

const std = @import("std");
const git_command = @import("command.zig");
const git_ref = @import("ref.zig");

pub const BranchKind = git_ref.BranchKind;

pub const CompareTargetSpec = struct {
    full_ref: []const u8,
    display_name: []const u8,
    kind: BranchKind,
};

pub const CompareTarget = struct {
    full_ref: []u8,
    display_name: []u8,
    kind: BranchKind,

    pub fn deinit(self: *CompareTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.full_ref);
        allocator.free(self.display_name);
        self.* = undefined;
    }
};

pub const DefaultTargetResult = union(enum) {
    target: CompareTarget,
    missing: CompareTarget,
    failed,

    pub fn deinit(self: *DefaultTargetResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .target, .missing => |*target| target.deinit(allocator),
            .failed => {},
        }
        self.* = .failed;
    }
};

pub const HeadNameResult = union(enum) {
    name: ?[]u8,
    failed,

    pub fn deinit(self: *HeadNameResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .name => |name| if (name) |bytes| allocator.free(bytes),
            .failed => {},
        }
        self.* = .failed;
    }
};

/// Apply the existing Compare fallback before invoking the strict target
/// resolver. The returned full ref is the resolver's explicit base input.
pub fn selectDefaultTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) git_command.Error!DefaultTargetResult {
    const origin_head_argv = [_][]const u8{
        "git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
    };
    switch (try runOptionalLine(allocator, io, context, &origin_head_argv, 4096)) {
        .line => |full_ref| {
            defer allocator.free(full_ref);
            var target = targetFromFullRef(allocator, full_ref) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .failed,
            };
            var target_owned = true;
            errdefer if (target_owned) target.deinit(allocator);
            switch (try refExists(allocator, io, context, target.full_ref)) {
                .present => {
                    target_owned = false;
                    return .{ .target = target };
                },
                .absent => {
                    target.deinit(allocator);
                    target_owned = false;
                },
                .failed => {
                    target.deinit(allocator);
                    target_owned = false;
                    return .failed;
                },
            }
        },
        .absent => {},
        .failed => return .failed,
    }

    var main = targetFromFullRef(allocator, "refs/heads/main") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCompareRef => unreachable,
    };
    var main_owned = true;
    errdefer if (main_owned) main.deinit(allocator);
    switch (try refExists(allocator, io, context, main.full_ref)) {
        .present => {
            main_owned = false;
            return .{ .target = main };
        },
        .absent => {
            main.deinit(allocator);
            main_owned = false;
        },
        .failed => {
            main.deinit(allocator);
            main_owned = false;
            return .failed;
        },
    }

    var master = targetFromFullRef(allocator, "refs/heads/master") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCompareRef => unreachable,
    };
    var master_owned = true;
    errdefer if (master_owned) master.deinit(allocator);
    return switch (try refExists(allocator, io, context, master.full_ref)) {
        .present => result: {
            master_owned = false;
            break :result .{ .target = master };
        },
        .absent => result: {
            master_owned = false;
            break :result .{ .missing = master };
        },
        .failed => result: {
            master.deinit(allocator);
            master_owned = false;
            break :result .failed;
        },
    };
}

/// Read the optional symbolic HEAD label for display only. A detached HEAD is
/// a successful null label and never changes target equality.
pub fn readHeadName(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) git_command.Error!HeadNameResult {
    const argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    return switch (try runOptionalLine(allocator, io, context, &argv, 4096)) {
        .line => |line| .{ .name = line },
        .absent => .{ .name = null },
        .failed => .failed,
    };
}

pub fn cloneTarget(allocator: std.mem.Allocator, spec: CompareTargetSpec) !CompareTarget {
    if (branchKind(spec.full_ref) != spec.kind) return error.InvalidCompareRef;
    const full_ref = try allocator.dupe(u8, spec.full_ref);
    errdefer allocator.free(full_ref);
    return .{
        .full_ref = full_ref,
        .display_name = try allocator.dupe(u8, spec.display_name),
        .kind = spec.kind,
    };
}

const OptionalLineResult = union(enum) {
    line: []u8,
    absent,
    failed,
};

fn runOptionalLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    limit: usize,
) git_command.Error!OptionalLineResult {
    const result = try git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = .limited(limit + 1),
        .stderr_limit = .limited(8 * 1024),
    });
    defer result.deinit(allocator);
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => result: {
                const line = singleLine(result.stdout) orelse return .failed;
                if (line.len == 0 or line.len > limit) return .failed;
                break :result .{ .line = try allocator.dupe(u8, line) };
            },
            1 => .absent,
            else => .failed,
        },
        else => .failed,
    };
}

const RefExistence = enum { present, absent, failed };

fn refExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    full_ref: []const u8,
) git_command.Error!RefExistence {
    const argv = [_][]const u8{ "git", "show-ref", "--exists", full_ref };
    const result = try git_command.runCaptured(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(8 * 1024),
    });
    defer result.deinit(allocator);
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => .present,
            2 => .absent,
            else => .failed,
        },
        else => .failed,
    };
}

fn targetFromFullRef(allocator: std.mem.Allocator, full_ref: []const u8) !CompareTarget {
    const kind = branchKind(full_ref) orelse return error.InvalidCompareRef;
    const prefix = switch (kind) {
        .local => "refs/heads/",
        .remote_tracking => "refs/remotes/",
    };
    return cloneTarget(allocator, .{
        .full_ref = full_ref,
        .display_name = full_ref[prefix.len..],
        .kind = kind,
    });
}

fn branchKind(full_ref: []const u8) ?BranchKind {
    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, full_ref, "refs/remotes/")) return .remote_tracking;
    return null;
}

fn singleLine(bytes: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, bytes, "\r\n");
    if (std.mem.indexOfScalar(u8, line, '\r') != null or std.mem.indexOfScalar(u8, line, '\n') != null) return null;
    return line;
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

test "Compare fallback policy selects origin HEAD then main without resolving target objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "a" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "a" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    var fallback = try selectDefaultTarget(std.testing.allocator, io, context);
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/heads/main", fallback.target.full_ref);

    try runTestGit(io, tmp.dir, &.{ "git", "update-ref", "refs/remotes/origin/main", "HEAD" });
    try runTestGit(io, tmp.dir, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    var preferred = try selectDefaultTarget(std.testing.allocator, io, context);
    defer preferred.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", preferred.target.full_ref);
}

test "Compare fallback policy retains master and missing-master terminals" {
    const io = std.testing.io;
    var master_tmp = std.testing.tmpDir(.{});
    defer master_tmp.cleanup();
    try runTestGit(io, master_tmp.dir, &.{ "git", "init", "--initial-branch=master" });
    try master_tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a\n" });
    try runTestGit(io, master_tmp.dir, &.{ "git", "add", "a" });
    try runTestGit(io, master_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "a" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var master = try selectDefaultTarget(std.testing.allocator, io, .{ .cwd = master_tmp.dir, .environment = &environment });
    defer master.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/heads/master", master.target.full_ref);

    var missing_tmp = std.testing.tmpDir(.{});
    defer missing_tmp.cleanup();
    try runTestGit(io, missing_tmp.dir, &.{ "git", "init", "--initial-branch=topic" });
    var missing = try selectDefaultTarget(std.testing.allocator, io, .{ .cwd = missing_tmp.dir, .environment = &environment });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/heads/master", missing.missing.full_ref);
}

test "Compare HEAD display policy accepts detached HEAD" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "a" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "a" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "--detach", "HEAD" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var name = try readHeadName(std.testing.allocator, io, .{ .cwd = tmp.dir, .environment = &environment });
    defer name.deinit(std.testing.allocator);
    try std.testing.expect(name.name == null);
}
