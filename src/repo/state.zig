const std = @import("std");
const repo_discovery = @import("discovery.zig");

/// Current repository discovery result plus active workspace selection.
///
/// Discovery owns paths returned by `repo_discovery`. The app owns picker UI and
/// load state; this type only answers "which repository is active right now?"
/// and releases the discovery result when it is replaced.
pub const State = struct {
    discovery: ?repo_discovery.DiscoveryResult = null,
    active_index: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.discovery) |*discovery| discovery.deinit(allocator);
        self.* = .{};
    }

    pub fn replace(self: *State, allocator: std.mem.Allocator, discovery: repo_discovery.DiscoveryResult) void {
        self.deinit(allocator);
        self.discovery = discovery;
        self.active_index = 0;
    }

    pub fn activeRoot(self: *const State) ?[]const u8 {
        const discovery = self.discovery orelse return null;
        return switch (discovery) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => |workspace| if (self.active_index < workspace.repos.len)
                workspace.repos[self.active_index].canonical_root
            else
                null,
            .none => null,
        };
    }

    pub fn workspaceRepos(self: *const State) ?[]const repo_discovery.RepoEntry {
        const discovery = self.discovery orelse return null;
        return switch (discovery) {
            .workspace => |workspace| workspace.repos,
            .single_repo, .none => null,
        };
    }

    pub fn needsDiscovery(self: *const State) bool {
        const discovery = self.discovery orelse return true;
        return discovery == .none;
    }
};

pub const RecentKind = enum {
    repo,
    workspace,
};

pub const RecentEntry = struct {
    kind: RecentKind,
    path: []u8,

    pub fn deinit(self: *RecentEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Session-local repository/workspace history.
///
/// Entries own canonical absolute paths. They intentionally do not borrow from
/// `DiscoveryResult`, because replacing repository discovery frees that data.
pub const RecentStore = struct {
    entries: std.ArrayList(RecentEntry) = .empty,

    pub fn deinit(self: *RecentStore, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn rememberRepo(self: *RecentStore, allocator: std.mem.Allocator, path: []const u8) !void {
        try self.remember(allocator, .repo, path);
    }

    pub fn rememberWorkspace(self: *RecentStore, allocator: std.mem.Allocator, path: []const u8) !void {
        try self.remember(allocator, .workspace, path);
    }

    pub fn rememberDiscovery(self: *RecentStore, allocator: std.mem.Allocator, discovery: repo_discovery.DiscoveryResult) !void {
        switch (discovery) {
            .single_repo => |entry| try self.rememberRepo(allocator, entry.canonical_root),
            .workspace => |workspace| {
                try self.rememberWorkspace(allocator, workspace.current_root);
                if (workspace.repos.len > 0) try self.rememberRepo(allocator, workspace.repos[0].canonical_root);
            },
            .none => {},
        }
    }

    fn remember(self: *RecentStore, allocator: std.mem.Allocator, kind: RecentKind, path: []const u8) !void {
        if (path.len == 0) return;
        if (self.find(kind, path)) |index| {
            if (index == 0) return;
            var entry = self.entries.orderedRemove(index);
            self.entries.insert(allocator, 0, entry) catch |err| {
                self.entries.insert(allocator, index, entry) catch {
                    entry.deinit(allocator);
                };
                return err;
            };
            return;
        }

        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.entries.insert(allocator, 0, .{ .kind = kind, .path = owned });
    }

    fn find(self: *const RecentStore, kind: RecentKind, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.kind == kind and std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }
};

test "active root follows workspace active index" {
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "one", .display_path = "one", .canonical_root = "/work/one" },
        .{ .label = "two", .display_path = "two", .canonical_root = "/work/two" },
    };
    const state: State = .{
        .discovery = .{ .workspace = .{
            .current_root = "/work",
            .repos = &repos,
        } },
        .active_index = 1,
    };

    try std.testing.expectEqualStrings("/work/two", state.activeRoot().?);
}

test "RecentStore owns and deduplicates paths" {
    const allocator = std.testing.allocator;
    var store: RecentStore = .{};
    defer store.deinit(allocator);

    try store.rememberRepo(allocator, "/tmp/one");
    try store.rememberRepo(allocator, "/tmp/two");
    try store.rememberRepo(allocator, "/tmp/one");

    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try std.testing.expectEqualStrings("/tmp/one", store.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/two", store.entries.items[1].path);
}
