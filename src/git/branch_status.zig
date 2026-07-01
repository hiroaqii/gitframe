const std = @import("std");

pub const ParseError = error{
    OutOfMemory,
    InvalidAheadBehind,
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

    pub fn parseOwned(allocator: std.mem.Allocator, text: []const u8) ParseError!BranchStatusBundle {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const copied = try arena.allocator().dupe(u8, text);
        return .{
            .arena = arena,
            .status = try parse(copied),
        };
    }

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

pub fn parse(text: []const u8) ParseError!BranchStatus {
    var status: BranchStatus = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "# branch.")) continue;
        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            status.oid = line["# branch.oid ".len..];
        } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const head = line["# branch.head ".len..];
            status.head = if (std.mem.eql(u8, head, "(detached)")) .detached else .{ .branch = head };
        } else if (std.mem.startsWith(u8, line, "# branch.upstream ")) {
            status.upstream = parseUpstream(line["# branch.upstream ".len..]);
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            status.ahead_behind = try parseAheadBehind(line["# branch.ab ".len..]);
        }
    }
    return status;
}

fn parseUpstream(name: []const u8) Upstream {
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

fn parseAheadBehind(text: []const u8) ParseError!AheadBehind {
    var iter = std.mem.tokenizeScalar(u8, text, ' ');
    const ahead_text = iter.next() orelse return error.InvalidAheadBehind;
    const behind_text = iter.next() orelse return error.InvalidAheadBehind;
    if (ahead_text.len < 2 or ahead_text[0] != '+') return error.InvalidAheadBehind;
    if (behind_text.len < 2 or behind_text[0] != '-') return error.InvalidAheadBehind;
    return .{
        .ahead = std.fmt.parseInt(u32, ahead_text[1..], 10) catch return error.InvalidAheadBehind,
        .behind = std.fmt.parseInt(u32, behind_text[1..], 10) catch return error.InvalidAheadBehind,
    };
}

test "parse branch status with upstream and ahead behind" {
    const status = try parse(
        "# branch.oid abc\n" ++
            "# branch.head feature\n" ++
            "# branch.upstream origin/main\n" ++
            "# branch.ab +2 -3\n",
    );

    try std.testing.expectEqualStrings("abc", status.oid.?);
    try std.testing.expectEqualStrings("feature", status.branchName().?);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?.name);
    try std.testing.expectEqualStrings("origin", status.upstream.?.remote);
    try std.testing.expectEqualStrings("main", status.upstream.?.remote_branch);
    try std.testing.expectEqual(@as(u32, 2), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 3), status.ahead_behind.?.behind);
}

test "parse detached branch status" {
    const status = try parse(
        "# branch.oid abc\n" ++
            "# branch.head (detached)\n",
    );

    try std.testing.expect(status.branchName() == null);
    try std.testing.expect(std.meta.eql(Head.detached, status.head));
    try std.testing.expect(status.upstream == null);
}

test "parse branch status without upstream" {
    const status = try parse(
        "# branch.oid abc\n" ++
            "# branch.head local-only\n",
    );

    try std.testing.expectEqualStrings("abc", status.oid.?);
    try std.testing.expectEqualStrings("local-only", status.branchName().?);
    try std.testing.expect(status.upstream == null);
    try std.testing.expect(status.ahead_behind == null);
}

test "parse zero ahead behind" {
    const status = try parse(
        "# branch.head main\n" ++
            "# branch.upstream origin/main\n" ++
            "# branch.ab +0 -0\n",
    );

    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.ahead);
    try std.testing.expectEqual(@as(u32, 0), status.ahead_behind.?.behind);
}

test "reject malformed ahead behind" {
    try std.testing.expectError(error.InvalidAheadBehind, parse(
        "# branch.head main\n" ++
            "# branch.ab +abc -xyz\n",
    ));
}
