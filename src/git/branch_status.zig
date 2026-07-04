const std = @import("std");

pub const ParseError = error{
    OutOfMemory,
};

pub const Head = union(enum) {
    branch: []const u8,
    detached,
    unknown,
};

pub const Upstream = struct {
    name: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
};

pub const AheadBehind = struct {
    ahead: u32 = 0,
    behind: u32 = 0,
};

/// Minimal branch/upstream snapshot for remote workflow gates.
///
/// This intentionally stays separate from porcelain file status so Phase 8.7
/// can add push/pull preconditions without migrating the hot file-status parser.
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
};

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

    pub fn setUpstream(self: *Builder, name: []const u8) std.mem.Allocator.Error!void {
        const copied = try self.allocator().dupe(u8, name);
        self.status.upstream = upstreamFromOwnedName(copied);
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

fn upstreamFromOwnedName(name: []const u8) Upstream {
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        return .{
            .name = name,
            .remote = name[0..slash],
            .remote_branch = name[slash + 1 ..],
        };
    }
    return .{
        .name = name,
        .remote = name,
        .remote_branch = "",
    };
}

test "builder creates branch status with upstream and ahead behind" {
    var builder = Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setOid("abc");
    try builder.setBranchHead("feature");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(2, 3);

    var bundle = builder.finish();
    defer bundle.deinit();
    const status = bundle.status;

    try std.testing.expectEqualStrings("abc", status.oid.?);
    try std.testing.expectEqualStrings("feature", status.branchName().?);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?.name);
    try std.testing.expectEqualStrings("origin", status.upstream.?.remote);
    try std.testing.expectEqualStrings("main", status.upstream.?.remote_branch);
    try std.testing.expectEqual(@as(u32, 2), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 3), status.ahead_behind.?.behind);
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
    try builder.setUpstream("origin/main");
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
    try builder.setUpstream("origin");

    var bundle = builder.finish();
    defer bundle.deinit();
    const upstream = bundle.status.upstream.?;

    try std.testing.expectEqualStrings("origin", upstream.name);
    try std.testing.expectEqualStrings("origin", upstream.remote);
    try std.testing.expectEqualStrings("", upstream.remote_branch);
}
