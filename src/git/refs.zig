//! Descriptor-bound branch status and branch-list reads.
//!
//! Callers own the physical repository root and sanitized environment. This
//! domain borrows one `DirectoryContext` for every command in a logical read;
//! display paths and ambient Git selectors are never repository authority.

const std = @import("std");
const git_branch_status = @import("branch_status.zig");
const git_command = @import("command.zig");
const git_ref = @import("ref.zig");
const process_runner = @import("../process/runner.zig");

pub const max_branch_list_bytes = 4 * 1024 * 1024;

pub const BranchStatusLoadResult = union(enum) {
    ok: git_branch_status.BranchStatusBundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: BranchStatusLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |bundle| {
                var owned = bundle;
                owned.deinit();
            },
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const BranchKind = git_ref.BranchKind;

pub const BranchListItem = struct {
    /// Full Git ref used as operation authority.
    full_ref: []u8,
    /// Short name used for display. This can collide across ref namespaces.
    name: []u8,
    kind: BranchKind,
    oid: []u8,
    current: bool = false,
    /// Committer timestamp of the commit at this ref's tip. This is populated
    /// only for callers that explicitly request it; malformed Git output is an
    /// item-local unknown rather than a whole-list failure.
    tip_committer_unix: ?i64 = null,
};

pub const BranchList = struct {
    current: ?[]u8 = null,
    branches: []BranchListItem = &.{},

    pub fn deinit(self: *BranchList, allocator: std.mem.Allocator) void {
        if (self.current) |current| allocator.free(current);
        for (self.branches) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        allocator.free(self.branches);
        self.* = .{};
    }
};

pub const BranchListLoadResult = union(enum) {
    ok: BranchList,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: BranchListLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |list| {
                var owned = list;
                owned.deinit(allocator);
            },
            .failed => |message| allocator.free(message),
            .failed_static => {},
        }
    }
};

pub const BranchStatusRequest = struct {
    /// One borrowed descriptor/environment pair for the complete snapshot.
    context: git_command.DirectoryContext,
};

pub const BranchListScope = enum {
    local,
    local_and_remote,
};

pub const BranchListRequest = struct {
    /// One borrowed descriptor/environment pair for the complete snapshot.
    context: git_command.DirectoryContext,
    scope: BranchListScope,
    include_tip_committer_unix: bool = false,
};

pub fn loadBranchStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: BranchStatusRequest,
) git_command.Error!BranchStatusLoadResult {
    var builder = git_branch_status.Builder.init(allocator);
    defer builder.deinit();

    const head_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const head_result = try runBranchCommand(allocator, io, request.context, &head_argv, .limited(4 * 1024));
    defer head_result.deinit(allocator);

    switch (head_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setBranchHead(trimLineEnd(head_result.stdout));
        } else {
            builder.setDetached();
        },
        else => return branchStatusCommandFailure(allocator, "git symbolic-ref", head_result),
    }

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    const oid_result = try runBranchCommand(allocator, io, request.context, &oid_argv, .limited(4 * 1024));
    defer oid_result.deinit(allocator);
    switch (oid_result.term) {
        .exited => |code| if (code == 0) {
            try builder.setOid(trimLineEnd(oid_result.stdout));
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse HEAD", oid_result),
    }

    const upstream_argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" };
    const upstream_result = try runBranchCommand(allocator, io, request.context, &upstream_argv, .limited(4 * 1024));
    defer upstream_result.deinit(allocator);
    var has_upstream = false;
    switch (upstream_result.term) {
        .exited => |code| if (code == 0) {
            has_upstream = true;
            try builder.setUpstream(trimLineEnd(upstream_result.stdout));
        } else {
            // No upstream is a normal local-branch/detached state.
        },
        else => return branchStatusCommandFailure(allocator, "git rev-parse upstream", upstream_result),
    }

    if (has_upstream) {
        const ab_argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" };
        const ab_result = try runBranchCommand(allocator, io, request.context, &ab_argv, .limited(4 * 1024));
        defer ab_result.deinit(allocator);
        switch (ab_result.term) {
            .exited => |code| if (code == 0) {
                const counts = try parseRevListAheadBehind(ab_result.stdout);
                builder.setAheadBehind(counts.ahead, counts.behind);
            } else {
                return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result);
            },
            else => return branchStatusCommandFailure(allocator, "git rev-list ahead/behind", ab_result),
        }
    }

    return .{ .ok = builder.finish() };
}

pub fn loadBranchList(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: BranchListRequest,
) git_command.Error!BranchListLoadResult {
    return loadBranchListWithLimit(allocator, io, request, .limited(max_branch_list_bytes));
}

fn loadBranchListWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: BranchListRequest,
    list_stdout_limit: std.Io.Limit,
) git_command.Error!BranchListLoadResult {
    const current_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" };
    const current_result = try runBranchCommand(allocator, io, request.context, &current_argv, .limited(4 * 1024));
    defer current_result.deinit(allocator);

    // Keep one fixed record schema for both callers. The typed request only
    // decides whether the timestamp fact is parsed/stored; it never changes
    // ordering or adds another subprocess for the normal branch picker.
    const format = "--format=%(refname)%00%(refname:short)%00%(objectname)%00%(symref)%00%(committerdate:unix)%00";
    const local_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads" };
    const all_argv = [_][]const u8{ "git", "for-each-ref", format, "refs/heads", "refs/remotes" };
    const list_argv: []const []const u8 = switch (request.scope) {
        .local => &local_argv,
        .local_and_remote => &all_argv,
    };
    const list_result = try runBranchCommand(allocator, io, request.context, list_argv, list_stdout_limit);
    defer list_result.deinit(allocator);

    return branchListResultFromCommandResultsWithTipTime(
        allocator,
        current_result,
        list_result,
        request.include_tip_committer_unix,
    );
}

fn runBranchCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) git_command.Error!process_runner.Result {
    return git_command.runCaptured(allocator, io, context, .{
        .argv = argv,
        .stdout_limit = stdout_limit,
        .stderr_limit = .limited(16 * 1024),
    });
}

fn branchListResultFromCommandResults(
    allocator: std.mem.Allocator,
    current_result: process_runner.Result,
    list_result: process_runner.Result,
) git_command.Error!BranchListLoadResult {
    return branchListResultFromCommandResultsWithTipTime(allocator, current_result, list_result, false);
}

fn branchListResultFromCommandResultsWithTipTime(
    allocator: std.mem.Allocator,
    current_result: process_runner.Result,
    list_result: process_runner.Result,
    include_tip_committer_unix: bool,
) git_command.Error!BranchListLoadResult {
    var current: ?[]u8 = null;
    defer if (current) |owned| allocator.free(owned);
    switch (current_result.term) {
        .exited => |code| if (code == 0) {
            current = allocator.dupe(u8, trimLineEnd(current_result.stdout)) catch return error.OutOfMemory;
        },
        else => {},
    }

    switch (list_result.term) {
        .exited => |code| if (code != 0) return branchListCommandFailure(allocator, list_result),
        else => return branchListCommandFailure(allocator, list_result),
    }

    var items: std.ArrayList(BranchListItem) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        items.deinit(allocator);
    }

    var index: usize = 0;
    while (index < list_result.stdout.len) {
        skipBranchListRecordSeparators(list_result.stdout, &index);
        if (index >= list_result.stdout.len) break;
        const full_ref_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const full_ref = list_result.stdout[index..full_ref_end];
        index = full_ref_end + 1;
        const name_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const name = list_result.stdout[index..name_end];
        index = name_end + 1;
        const oid_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const oid = list_result.stdout[index..oid_end];
        index = oid_end + 1;
        const symref_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const symref = list_result.stdout[index..symref_end];
        index = symref_end + 1;
        const timestamp_end = std.mem.indexOfScalarPos(u8, list_result.stdout, index, 0) orelse break;
        const timestamp = list_result.stdout[index..timestamp_end];
        index = timestamp_end + 1;
        const tip_committer_unix: ?i64 = if (include_tip_committer_unix)
            std.fmt.parseInt(i64, timestamp, 10) catch null
        else
            null;
        if (full_ref.len == 0 or name.len == 0 or oid.len == 0) continue;

        const kind = branchKind(full_ref) orelse continue;
        if (kind == .remote_tracking and symref.len != 0 and std.mem.endsWith(u8, full_ref, "/HEAD")) continue;

        const owned_full_ref = allocator.dupe(u8, full_ref) catch return error.OutOfMemory;
        const owned_name = allocator.dupe(u8, name) catch {
            allocator.free(owned_full_ref);
            return error.OutOfMemory;
        };
        const owned_oid = allocator.dupe(u8, oid) catch {
            allocator.free(owned_full_ref);
            allocator.free(owned_name);
            return error.OutOfMemory;
        };
        items.append(allocator, .{
            .full_ref = owned_full_ref,
            .name = owned_name,
            .kind = kind,
            .oid = owned_oid,
            .current = kind == .local and current != null and std.mem.eql(u8, current.?, name),
            .tip_committer_unix = tip_committer_unix,
        }) catch {
            allocator.free(owned_full_ref);
            allocator.free(owned_name);
            allocator.free(owned_oid);
            return error.OutOfMemory;
        };
    }

    const branches = items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const owned_current = current;
    current = null;
    return .{ .ok = .{ .current = owned_current, .branches = branches } };
}

fn branchKind(full_ref: []const u8) ?BranchKind {
    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, full_ref, "refs/remotes/")) return .remote_tracking;
    return null;
}

fn skipBranchListRecordSeparators(output: []const u8, index: *usize) void {
    // `git for-each-ref --format=...%00...%00` still writes its normal record
    // newline after each formatted ref. Branch names are NUL fields, so consume
    // only those record separators before reading the next branch name.
    while (index.* < output.len and (output[index.*] == '\n' or output[index.*] == '\r')) : (index.* += 1) {}
}

fn branchListCommandFailure(
    allocator: std.mem.Allocator,
    result: process_runner.Result,
) git_command.Error!BranchListLoadResult {
    if (result.stderr.len > 0) return .{ .failed = allocator.dupe(u8, result.stderr) catch return error.OutOfMemory };
    return .{ .failed = std.fmt.allocPrint(allocator, "git branch list failed: {any}", .{result.term}) catch return error.OutOfMemory };
}

fn branchStatusCommandFailure(
    allocator: std.mem.Allocator,
    label: []const u8,
    result: process_runner.Result,
) git_command.Error!BranchStatusLoadResult {
    if (result.stderr.len > 0) return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{ label, trimLineEnd(result.stderr) }) };
    return .{ .failed = try std.fmt.allocPrint(allocator, "{s} failed: {any}", .{ label, result.term }) };
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

const RevListAheadBehind = struct {
    ahead: u32,
    behind: u32,
};

fn parseRevListAheadBehind(text: []const u8) git_command.Error!RevListAheadBehind {
    var iter = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const ahead_text = iter.next() orelse return error.SpawnFailed;
    const behind_text = iter.next() orelse return error.SpawnFailed;
    return .{
        .ahead = std.fmt.parseInt(u32, ahead_text, 10) catch return error.SpawnFailed,
        .behind = std.fmt.parseInt(u32, behind_text, 10) catch return error.SpawnFailed,
    };
}

test "skipBranchListRecordSeparators preserves branch name after for-each-ref newline" {
    const output = "\nrefs/heads/zig-port\x00zig-port\x00abc\x00\x00";
    var index: usize = 0;
    skipBranchListRecordSeparators(output, &index);
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqualStrings("refs/heads/zig-port", output[index .. index + "refs/heads/zig-port".len]);
}

test "branch list non-zero result releases current and preserves stderr" {
    var current_stdout = "main\n".*;
    var list_stderr = "fatal: branch list failed\n".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{ .term = .{ .exited = 0 }, .stdout = &current_stdout, .stderr = &empty },
        .{ .term = .{ .exited = 128 }, .stdout = &empty, .stderr = &list_stderr },
    );
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| try std.testing.expectEqualStrings(&list_stderr, message),
        .ok, .failed_static => return error.ExpectedBranchListFailure,
    }
}

test "branch list abnormal result releases current and preserves termination" {
    var current_stdout = "main\n".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{ .term = .{ .exited = 0 }, .stdout = &current_stdout, .stderr = &empty },
        .{ .term = .{ .unknown = 9 }, .stdout = &empty, .stderr = &empty },
    );
    defer result.deinit(std.testing.allocator);

    switch (result) {
        .failed => |message| {
            try std.testing.expect(std.mem.indexOf(u8, message, "unknown") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "9") != null);
        },
        .ok, .failed_static => return error.ExpectedBranchListFailure,
    }
}

test "branch list diagnostic allocation failure releases current" {
    var current_stdout = "main\n".*;
    var list_stderr = "fatal: branch list failed\n".*;
    var empty: [0]u8 = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });

    try std.testing.expectError(error.OutOfMemory, branchListResultFromCommandResults(
        failing.allocator(),
        .{ .term = .{ .exited = 0 }, .stdout = &current_stdout, .stderr = &empty },
        .{ .term = .{ .exited = 128 }, .stdout = &empty, .stderr = &list_stderr },
    ));
}

test "branch list success transfers current ownership exactly once" {
    var current_stdout = "main\n".*;
    var list_stdout = "refs/heads/main\x00main\x00abc\x00\x001700000001\x00\nrefs/heads/feature/topic\x00feature/topic\x00def\x00\x001700000002\x00".*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResults(
        std.testing.allocator,
        .{ .term = .{ .exited = 0 }, .stdout = &current_stdout, .stderr = &empty },
        .{ .term = .{ .exited = 0 }, .stdout = &list_stdout, .stderr = &empty },
    );
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expectEqualStrings("main", list.current.?);
    try std.testing.expectEqual(@as(usize, 2), list.branches.len);
    try std.testing.expectEqualStrings("refs/heads/main", list.branches[0].full_ref);
    try std.testing.expectEqualStrings("main", list.branches[0].name);
    try std.testing.expectEqual(BranchKind.local, list.branches[0].kind);
    try std.testing.expect(list.branches[0].current);
    try std.testing.expectEqualStrings("feature/topic", list.branches[1].name);
    try std.testing.expect(!list.branches[1].current);
    try std.testing.expect(list.branches[0].tip_committer_unix == null);
    try std.testing.expect(list.branches[1].tip_committer_unix == null);
}

test "branch list typed tip time parses per item without reordering or whole-list failure" {
    var current_stdout = "main\n".*;
    var list_stdout = ("refs/heads/zeta\x00zeta\x00abc\x00\x001700000001\x00\n" ++
        "refs/heads/alpha\x00alpha\x00def\x00\x00not-a-time\x00\n" ++
        "refs/remotes/origin/topic\x00origin/topic\x00123\x00\x001700000003\x00").*;
    var empty: [0]u8 = .{};
    const result = try branchListResultFromCommandResultsWithTipTime(
        std.testing.allocator,
        .{ .term = .{ .exited = 0 }, .stdout = &current_stdout, .stderr = &empty },
        .{ .term = .{ .exited = 0 }, .stdout = &list_stdout, .stderr = &empty },
        true,
    );
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |value| value,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expectEqual(@as(usize, 3), list.branches.len);
    try std.testing.expectEqualStrings("refs/heads/zeta", list.branches[0].full_ref);
    try std.testing.expectEqual(@as(?i64, 1_700_000_001), list.branches[0].tip_committer_unix);
    try std.testing.expectEqualStrings("refs/heads/alpha", list.branches[1].full_ref);
    try std.testing.expect(list.branches[1].tip_committer_unix == null);
    try std.testing.expectEqualStrings("refs/remotes/origin/topic", list.branches[2].full_ref);
    try std.testing.expectEqual(@as(?i64, 1_700_000_003), list.branches[2].tip_committer_unix);
}

test "refs loads local branch list without record separator newlines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchListFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    const result = try loadBranchList(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .scope = .local,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expectEqualStrings("main", list.current.?);
    try expectBranchListed(list.branches, "main");
    try expectBranchListed(list.branches, "feature/topic");
    try expectBranchNotListed(list.branches, "origin/remote-only");
    const main = branchByFullRef(list.branches, "refs/heads/main") orelse return error.ExpectedBranchListed;
    try std.testing.expectEqual(BranchKind.local, main.kind);
    try std.testing.expect(main.current);
    for (list.branches) |branch| {
        try std.testing.expect(std.mem.indexOfScalar(u8, branch.name, '\n') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, branch.name, '\r') == null);
    }
}

test "refs loads distinct local and remote refs and excludes every remote HEAD symref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchListFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    try runTestGit(io, &.{ "git", "config", "core.warnAmbiguousRefs", "true" }, work);
    try runTestGit(io, &.{ "git", "branch", "origin/main", "main" }, work);
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, work);
    try runTestGit(io, &.{ "git", "update-ref", "refs/remotes/upstream/main", fixture.main_oid }, work);
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/main" }, work);

    const result = try loadBranchList(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .scope = .local_and_remote,
        .include_tip_committer_unix = true,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |list| list,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    const local_collision = branchByFullRef(list.branches, "refs/heads/origin/main") orelse
        return error.ExpectedBranchListed;
    const remote_collision = branchByFullRef(list.branches, "refs/remotes/origin/main") orelse
        return error.ExpectedBranchListed;
    const remote_only = branchByFullRef(list.branches, "refs/remotes/origin/remote-only") orelse
        return error.ExpectedBranchListed;
    const current = branchByFullRef(list.branches, "refs/heads/main") orelse
        return error.ExpectedBranchListed;

    try std.testing.expectEqualStrings("heads/origin/main", local_collision.name);
    try std.testing.expectEqualStrings("remotes/origin/main", remote_collision.name);
    try std.testing.expectEqual(BranchKind.local, local_collision.kind);
    try std.testing.expectEqual(BranchKind.remote_tracking, remote_collision.kind);
    try std.testing.expectEqual(BranchKind.remote_tracking, remote_only.kind);
    try std.testing.expectEqualStrings(fixture.main_oid, local_collision.oid);
    try std.testing.expectEqualStrings(fixture.main_oid, remote_collision.oid);
    try std.testing.expect(local_collision.tip_committer_unix != null);
    try std.testing.expect(remote_collision.tip_committer_unix != null);
    try std.testing.expect(remote_only.tip_committer_unix != null);
    try std.testing.expect(current.current);
    try std.testing.expect(!remote_collision.current);
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/origin/HEAD") == null);
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/upstream/HEAD") == null);
}

test "refs loads a local and remote branch list larger than four KiB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchListFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    const remote_ref_count = 80;
    var ref_buffer: [160]u8 = undefined;
    for (0..remote_ref_count) |index| {
        const full_ref = try std.fmt.bufPrint(
            &ref_buffer,
            "refs/remotes/origin/feature-{d}-with-a-realistic-name-for-compare-picker",
            .{index},
        );
        try runTestGit(io, &.{ "git", "update-ref", full_ref, fixture.main_oid }, work);
    }
    try runTestGit(io, &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" }, work);

    const result = try loadBranchList(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
        .scope = .local_and_remote,
    });
    defer result.deinit(std.testing.allocator);

    const list = switch (result) {
        .ok => |value| value,
        .failed, .failed_static => return error.ExpectedBranchList,
    };
    try std.testing.expect(list.branches.len >= remote_ref_count);
    for (0..remote_ref_count) |index| {
        const full_ref = try std.fmt.bufPrint(
            &ref_buffer,
            "refs/remotes/origin/feature-{d}-with-a-realistic-name-for-compare-picker",
            .{index},
        );
        const branch = branchByFullRef(list.branches, full_ref) orelse return error.ExpectedBranchListed;
        try std.testing.expectEqual(BranchKind.remote_tracking, branch.kind);
        try std.testing.expectEqualStrings(fixture.main_oid, branch.oid);
    }
    try std.testing.expect(branchByFullRef(list.branches, "refs/remotes/origin/HEAD") == null);
}

test "branch list reports StreamTooLong at its explicit bounded capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const fixture = try setupBranchListFixture(io, &tmp);
    defer fixture.deinit();
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    try std.testing.expectError(error.StreamTooLong, loadBranchListWithLimit(
        std.testing.allocator,
        io,
        .{
            .context = .{ .cwd = work, .environment = &environment },
            .scope = .local_and_remote,
        },
        .limited(1),
    ));
}

test "refs loads branch status without upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, tmp.dir);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, tmp.dir);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    const result = try loadBranchStatus(std.testing.allocator, io, .{
        .context = .{ .cwd = tmp.dir, .environment = &environment },
    });
    defer result.deinit(std.testing.allocator);

    const status = switch (result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };
    try std.testing.expectEqualStrings("main", status.branchName().?);
    try std.testing.expect(status.oid != null);
    try std.testing.expect(status.upstream == null);
    try std.testing.expect(status.ahead_behind == null);
}

test "refs loads branch status with upstream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "main" }, work);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();

    const result = try loadBranchStatus(std.testing.allocator, io, .{
        .context = .{ .cwd = work, .environment = &environment },
    });
    defer result.deinit(std.testing.allocator);

    const status = switch (result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };
    try std.testing.expectEqualStrings("main", status.branchName().?);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?.name);
    try std.testing.expectEqualStrings("origin", status.upstream.?.remote);
    try std.testing.expectEqualStrings("main", status.upstream.?.remote_branch);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.behind);
}

test "branch status descriptor cwd survives path replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote-pinned.git" }, tmp.dir);
    try runTestGit(io, &.{ "git", "init", "--bare", "remote-replacement.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "replacement", .default_dir);
    var pinned = try tmp.dir.openDir(io, "work", .{});
    defer pinned.close(io);
    var replacement = try tmp.dir.openDir(io, "replacement", .{});
    defer replacement.close(io);

    const pinned_remote = try tmp.dir.realPathFileAlloc(io, "remote-pinned.git", std.testing.allocator);
    defer std.testing.allocator.free(pinned_remote);
    const replacement_remote = try tmp.dir.realPathFileAlloc(io, "remote-replacement.git", std.testing.allocator);
    defer std.testing.allocator.free(replacement_remote);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=pinned" }, pinned);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", pinned_remote }, pinned);
    try pinned.writeFile(io, .{ .sub_path = "PINNED.md", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "PINNED.md" }, pinned);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "pinned base" }, pinned);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "pinned" }, pinned);
    try pinned.writeFile(io, .{ .sub_path = "PINNED.md", .data = "base\nahead\n" });
    try runTestGit(io, &.{ "git", "add", "PINNED.md" }, pinned);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "pinned ahead" }, pinned);
    const pinned_oid = try gitOutputAlloc(io, pinned, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(pinned_oid);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=replacement" }, replacement);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", replacement_remote }, replacement);
    try replacement.writeFile(io, .{ .sub_path = "REPLACEMENT.md", .data = "replacement\n" });
    try runTestGit(io, &.{ "git", "add", "REPLACEMENT.md" }, replacement);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "replacement base" }, replacement);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "replacement" }, replacement);
    const replacement_oid = try gitOutputAlloc(io, replacement, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(replacement_oid);
    try std.testing.expect(!std.mem.eql(u8, trimLineEnd(pinned_oid), trimLineEnd(replacement_oid)));

    try tmp.dir.rename("work", tmp.dir, "pinned-work", io);
    try tmp.dir.rename("replacement", tmp.dir, "work", io);
    const replacement_path = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(replacement_path);
    const replacement_git_dir = try std.fs.path.join(std.testing.allocator, &.{ replacement_path, ".git" });
    defer std.testing.allocator.free(replacement_git_dir);
    var redirect_env = std.process.Environ.Map.init(std.testing.allocator);
    defer redirect_env.deinit();
    try redirect_env.put("GIT_DIR", replacement_git_dir);
    try redirect_env.put("GIT_WORK_TREE", replacement_path);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &redirect_env);
    defer environment.deinit();

    const pinned_result = try loadBranchStatus(std.testing.allocator, io, .{
        .context = .{ .cwd = pinned, .environment = &environment },
    });
    defer pinned_result.deinit(std.testing.allocator);
    const replacement_result = try loadBranchStatus(std.testing.allocator, io, .{
        .context = .{ .cwd = replacement, .environment = &environment },
    });
    defer replacement_result.deinit(std.testing.allocator);

    const pinned_status = switch (pinned_result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };
    const replacement_status = switch (replacement_result) {
        .ok => |bundle| bundle.status,
        .failed, .failed_static => return error.UnexpectedBranchStatusFailure,
    };
    try std.testing.expectEqualStrings("pinned", pinned_status.branchName().?);
    try std.testing.expectEqualStrings(trimLineEnd(pinned_oid), pinned_status.oid.?);
    try std.testing.expectEqualStrings("origin/pinned", pinned_status.upstream.?.name);
    try std.testing.expectEqual(@as(u32, 1), pinned_status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), pinned_status.ahead_behind.?.behind);
    try std.testing.expectEqualStrings("replacement", replacement_status.branchName().?);
    try std.testing.expectEqualStrings(trimLineEnd(replacement_oid), replacement_status.oid.?);
    try std.testing.expectEqualStrings("origin/replacement", replacement_status.upstream.?.name);
    try std.testing.expectEqual(@as(u32, 0), replacement_status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), replacement_status.ahead_behind.?.behind);
}

const BranchListFixture = struct {
    main_oid: []u8,

    fn deinit(self: BranchListFixture) void {
        std.testing.allocator.free(self.main_oid);
    }
};

fn setupBranchListFixture(io: std.Io, tmp: *std.testing.TmpDir) !BranchListFixture {
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "updater", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    var updater = try tmp.dir.openDir(io, "updater", .{});
    defer updater.close(io);
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "main\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "push", "-u", "origin", "main" }, work);
    const main_output = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(main_output);
    const main_oid = try std.testing.allocator.dupe(u8, trimLineEnd(main_output));
    errdefer std.testing.allocator.free(main_oid);

    try runTestGit(io, &.{ "git", "switch", "-c", "feature/topic" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, work);
    try runTestGit(io, &.{ "git", "switch", "main" }, work);
    try runTestGit(io, &.{ "git", "push", "origin", "feature/topic" }, work);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, updater);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, updater);
    try runTestGit(io, &.{ "git", "pull", "--ff-only", "origin", "main" }, updater);
    try runTestGit(io, &.{ "git", "switch", "-c", "remote-only" }, updater);
    try updater.writeFile(io, .{ .sub_path = "REMOTE.md", .data = "remote\n" });
    try runTestGit(io, &.{ "git", "add", "REMOTE.md" }, updater);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "remote only" }, updater);
    try runTestGit(io, &.{ "git", "push", "origin", "remote-only" }, updater);
    try runTestGit(io, &.{ "git", "fetch", "origin" }, work);
    return .{ .main_oid = main_oid };
}

fn expectBranchListed(branches: []const BranchListItem, name: []const u8) !void {
    for (branches) |branch| if (std.mem.eql(u8, branch.name, name)) return;
    return error.ExpectedBranchListed;
}

fn expectBranchNotListed(branches: []const BranchListItem, name: []const u8) !void {
    for (branches) |branch| if (std.mem.eql(u8, branch.name, name)) return error.ExpectedBranchNotListed;
}

fn branchByFullRef(branches: []const BranchListItem, full_ref: []const u8) ?*const BranchListItem {
    for (branches) |*branch| if (std.mem.eql(u8, branch.full_ref, full_ref)) return branch;
    return null;
}

fn runTestGit(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(result);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn gitOutputAlloc(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(result);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    freeRunResult(result);
    return error.GitCommandFailed;
}

fn freeRunResult(result: std.process.RunResult) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}
