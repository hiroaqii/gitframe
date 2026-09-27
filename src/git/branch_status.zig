const std = @import("std");
const git_ref = @import("ref.zig");

pub const ParseError = error{
    OutOfMemory,
};

pub const Head = union(enum) {
    branch: []const u8,
    detached,
    unknown,
};

pub const Upstream = struct {
    /// Display label only; remote and ref authority come from separate Git fields.
    name: []const u8,
    full_ref: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
};

pub const upstream_format = "--format=%(refname)%00%(upstream)%00%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)%00";

/// Borrows the exact local branch's structured record from a Git capture.
pub fn parseUpstreamRecord(output: []const u8, local_ref: []const u8) error{InvalidUpstream}!?Upstream {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0);
        const ref = fields.next() orelse return error.InvalidUpstream;
        const full_ref = fields.next() orelse return error.InvalidUpstream;
        const name = fields.next() orelse return error.InvalidUpstream;
        const remote = fields.next() orelse return error.InvalidUpstream;
        const remote_ref = fields.next() orelse return error.InvalidUpstream;
        const tail = fields.next() orelse return error.InvalidUpstream;
        if (tail.len != 0 or fields.next() != null) return error.InvalidUpstream;
        if (!std.mem.eql(u8, ref, local_ref)) continue;
        if (full_ref.len == 0) {
            if (name.len != 0 or remote.len != 0 or remote_ref.len != 0) return error.InvalidUpstream;
            return null;
        }
        if (name.len == 0 or !std.mem.startsWith(u8, full_ref, "refs/")) return error.InvalidUpstream;
        return .{
            .name = name,
            .full_ref = full_ref,
            .remote = remote,
            .remote_branch = if (remote.len == 0 or std.mem.eql(u8, remote, ".")) "" else git_ref.localBranchName(remote_ref) orelse "",
        };
    }
    return null; // Unborn branch or no exact local ref.
}

pub const AheadBehind = struct {
    ahead: u32 = 0,
    behind: u32 = 0,
};

/// Minimal branch/upstream snapshot for remote workflow gates.
///
/// This intentionally stays separate from porcelain file status so push/pull
/// preconditions do not migrate into the hot file-status parser.
pub const BranchStatus = struct {
    oid: ?[]const u8 = null,
    head: Head = .unknown,
    upstream: ?Upstream = null,
    ahead_behind: ?AheadBehind = null,

    pub fn branchName(self: BranchStatus) ?[]const u8 {
        return switch (self.head) {
            .branch => |name| name,
            .detached, .unknown => null,
        };
    }

    pub fn eql(lhs: BranchStatus, rhs: BranchStatus) bool {
        if (!optionalTextEql(lhs.oid, rhs.oid)) return false;
        if (!headEql(lhs.head, rhs.head)) return false;
        if (!upstreamEql(lhs.upstream, rhs.upstream)) return false;
        return std.meta.eql(lhs.ahead_behind, rhs.ahead_behind);
    }
};

fn optionalTextEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn headEql(lhs: Head, rhs: Head) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .branch => |name| std.mem.eql(u8, name, rhs.branch),
        .detached, .unknown => true,
    };
}

fn upstreamEql(lhs: ?Upstream, rhs: ?Upstream) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    const left = lhs.?;
    const right = rhs.?;
    return std.mem.eql(u8, left.name, right.name) and
        std.mem.eql(u8, left.full_ref, right.full_ref) and
        std.mem.eql(u8, left.remote, right.remote) and
        std.mem.eql(u8, left.remote_branch, right.remote_branch);
}

pub const BranchStatusBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    status: BranchStatus,

    pub fn deinit(self: *BranchStatusBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{ .arena = null, .status = .{} };
    }

    pub fn takeArena(self: *BranchStatusBundle) std.heap.ArenaAllocator {
        const arena = self.arena.?;
        self.arena = null;
        return arena;
    }
};

pub const Builder = struct {
    arena: ?std.heap.ArenaAllocator,
    status: BranchStatus = .{},

    pub fn init(parent_allocator: std.mem.Allocator) Builder {
        return .{ .arena = .init(parent_allocator) };
    }

    pub fn deinit(self: *Builder) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{ .arena = null, .status = .{} };
    }

    pub fn setOid(self: *Builder, oid: []const u8) std.mem.Allocator.Error!void {
        self.status.oid = try self.allocator().dupe(u8, oid);
    }

    pub fn setBranchHead(self: *Builder, name: []const u8) std.mem.Allocator.Error!void {
        self.status.head = .{ .branch = try self.allocator().dupe(u8, name) };
    }

    pub fn setDetached(self: *Builder) void {
        self.status.head = .detached;
    }

    pub fn setUpstream(self: *Builder, upstream: Upstream) std.mem.Allocator.Error!void {
        self.status.upstream = .{
            .name = try self.allocator().dupe(u8, upstream.name),
            .full_ref = try self.allocator().dupe(u8, upstream.full_ref),
            .remote = try self.allocator().dupe(u8, upstream.remote),
            .remote_branch = try self.allocator().dupe(u8, upstream.remote_branch),
        };
    }

    pub fn setAheadBehind(self: *Builder, ahead: u32, behind: u32) void {
        self.status.ahead_behind = .{ .ahead = ahead, .behind = behind };
    }

    pub fn finish(self: *Builder) BranchStatusBundle {
        const arena = self.arena.?;
        const status = self.status;
        self.* = .{ .arena = null, .status = .{} };
        return .{ .arena = arena, .status = status };
    }

    fn allocator(self: *Builder) std.mem.Allocator {
        return self.arena.?.allocator();
    }
};

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    repo_root: ?[]const u8 = null,
    status: BranchStatus = .{},

    pub fn replace(self: *State, repo_root: []const u8, bundle: *BranchStatusBundle) ParseError!void {
        var arena = bundle.takeArena();
        errdefer arena.deinit();

        const copied_root = try arena.allocator().dupe(u8, repo_root);
        self.deinit();
        self.arena = arena;
        self.repo_root = copied_root;
        self.status = bundle.status;
    }

    pub fn clear(self: *State) void {
        self.deinit();
    }

    pub fn deinit(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

test "builder creates branch status with upstream and ahead behind" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setOid("abc");
    try builder.setBranchHead("feature");
    try builder.setUpstream(.{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" });
    builder.setAheadBehind(2, 3);

    var bundle = builder.finish();
    defer bundle.deinit();
    const status = bundle.status;

    try std.testing.expectEqualStrings("abc", status.oid.?);
    try std.testing.expectEqualStrings("feature", status.branchName().?);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?.name);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", status.upstream.?.full_ref);
    try std.testing.expectEqualStrings("origin", status.upstream.?.remote);
    try std.testing.expectEqualStrings("main", status.upstream.?.remote_branch);
    try std.testing.expectEqual(@as(u32, 2), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 3), status.ahead_behind.?.behind);
}

test "structured upstream record keeps authority separate and rejects incomplete fields" {
    const local_ref = "refs/heads/main";
    const record = "refs/heads/main\x00refs/remotes/selected/main\x00selected/main\x00team/origin\x00refs/heads/topic\x00\n";
    const upstream = (try parseUpstreamRecord(record, local_ref)).?;
    try std.testing.expectEqualStrings("selected/main", upstream.name);
    try std.testing.expectEqualStrings("refs/remotes/selected/main", upstream.full_ref);
    try std.testing.expectEqualStrings("team/origin", upstream.remote);
    try std.testing.expectEqualStrings("topic", upstream.remote_branch);
    try std.testing.expect(try parseUpstreamRecord(record, "refs/heads/mai") == null);
    try std.testing.expect(try parseUpstreamRecord("refs/heads/main\x00\x00\x00\x00\x00\n", local_ref) == null);
    try std.testing.expect(try parseUpstreamRecord("", local_ref) == null);
    try std.testing.expectError(error.InvalidUpstream, parseUpstreamRecord("refs/heads/main\x00refs/remotes/selected/main\x00", local_ref));
    const local = (try parseUpstreamRecord("refs/heads/main\x00refs/heads/topic\x00topic\x00.\x00refs/heads/topic\x00\n", local_ref)).?;
    try std.testing.expectEqualStrings("", local.remote_branch);
    const tag = (try parseUpstreamRecord("refs/heads/main\x00refs/tags/v1\x00v1\x00origin\x00refs/tags/v1\x00\n", local_ref)).?;
    try std.testing.expectEqualStrings("", tag.remote_branch);
}

test "builder creates detached branch status" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setOid("abc");
    builder.setDetached();

    var bundle = builder.finish();
    defer bundle.deinit();
    const status = bundle.status;

    try std.testing.expect(status.branchName() == null);
    try std.testing.expect(std.meta.eql(Head.detached, status.head));
    try std.testing.expect(status.upstream == null);
}

test "builder creates branch status without upstream" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setOid("abc");
    try builder.setBranchHead("local-only");

    var bundle = builder.finish();
    defer bundle.deinit();
    const status = bundle.status;

    try std.testing.expectEqualStrings("abc", status.oid.?);
    try std.testing.expectEqualStrings("local-only", status.branchName().?);
    try std.testing.expect(status.upstream == null);
    try std.testing.expect(status.ahead_behind == null);
}

test "builder creates zero ahead behind" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    try builder.setUpstream(.{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" });
    builder.setAheadBehind(0, 0);

    var bundle = builder.finish();
    defer bundle.deinit();
    const status = bundle.status;

    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.behind);
}

test "builder preserves upstream without remote branch" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("main");
    try builder.setUpstream(.{ .name = "origin", .full_ref = "refs/remotes/origin", .remote = "origin", .remote_branch = "" });

    var bundle = builder.finish();
    defer bundle.deinit();
    const upstream = bundle.status.upstream.?;

    try std.testing.expectEqualStrings("origin", upstream.name);
    try std.testing.expectEqualStrings("origin", upstream.remote);
    try std.testing.expectEqualStrings("", upstream.remote_branch);
}

test "branch status equality compares borrowed values" {
    const first: BranchStatus = .{
        .oid = "abc",
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 1, .behind = 2 },
    };
    try std.testing.expect(first.eql(first));
    var changed = first;
    changed.ahead_behind = .{ .ahead = 2, .behind = 1 };
    try std.testing.expect(!first.eql(changed));
}
