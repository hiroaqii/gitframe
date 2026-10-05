const std = @import("std");
const config = @import("../config.zig");
const repo_discovery = @import("discovery.zig");
const root_capability = @import("root_capability.zig");

pub const max_recent_entries = 32;

/// Current repository discovery result plus active workspace selection.
///
/// Discovery owns paths returned by `repo_discovery`. The app owns picker UI and
/// load state; this type only answers "which repository is active right now?"
/// and releases the discovery result when it is replaced.
pub const State = struct {
    discovery: ?repo_discovery.DiscoveryResult = null,
    active_index: usize = 0,
    root: ?root_capability.RootCapability = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.discovery) |*discovery| discovery.deinit(allocator);
        if (self.root) |*root| root.deinit();
        self.* = .{};
    }

    /// Atomically replace path metadata and the matching committed root owner.
    pub fn replaceCommitted(
        self: *State,
        allocator: std.mem.Allocator,
        discovery: repo_discovery.DiscoveryResult,
        active_index: usize,
        root: ?root_capability.RootCapability,
    ) void {
        self.deinit(allocator);
        self.discovery = discovery;
        self.active_index = active_index;
        self.root = root;
    }

    /// Replace refreshed discovery metadata while retaining the exact same
    /// root capability committed for the unchanged path/object identity.
    pub fn replaceDiscoveryKeepingRoot(
        self: *State,
        allocator: std.mem.Allocator,
        discovery: repo_discovery.DiscoveryResult,
        active_index: usize,
    ) void {
        if (self.discovery) |*old| old.deinit(allocator);
        self.discovery = discovery;
        self.active_index = active_index;
    }

    /// Commit a workspace selection and its already-open matching capability.
    pub fn selectWorkspaceRoot(
        self: *State,
        active_index: usize,
        root: root_capability.RootCapability,
    ) void {
        if (self.root) |*old| old.deinit();
        self.active_index = active_index;
        self.root = root;
    }

    pub fn selectWorkspaceIndexKeepingRoot(self: *State, active_index: usize) void {
        self.active_index = active_index;
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

    pub fn activeCapability(self: *const State) ?*const root_capability.RootCapability {
        return if (self.root) |*root| root else null;
    }

    pub fn activeIdentity(self: *const State) ?root_capability.Identity {
        return if (self.root) |root| root.identity else null;
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

    pub fn prepareRememberWorkspace(
        self: *const RecentStore,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !RecentStore {
        var next = try self.clone(allocator);
        errdefer next.deinit(allocator);
        try next.rememberWorkspace(allocator, path);
        return next;
    }

    pub fn prepareRemoval(
        self: *const RecentStore,
        allocator: std.mem.Allocator,
        preferred_index: usize,
        kind: RecentKind,
        path: []const u8,
    ) !?RecentStore {
        var next = try self.clone(allocator);
        errdefer next.deinit(allocator);
        const removed = if (next.entryMatches(preferred_index, kind, path))
            next.removeAt(allocator, preferred_index)
        else
            next.removeFirstMatching(allocator, kind, path);
        if (!removed) {
            next.deinit(allocator);
            return null;
        }
        return next;
    }

    pub fn rememberDiscovery(self: *RecentStore, allocator: std.mem.Allocator, discovery: repo_discovery.DiscoveryResult) !void {
        switch (discovery) {
            .single_repo => |entry| try self.rememberRepo(allocator, entry.canonical_root),
            .workspace => |workspace| try self.rememberWorkspaceDiscovery(allocator, workspace),
            .none => {},
        }
    }

    pub fn removeAt(self: *RecentStore, allocator: std.mem.Allocator, index: usize) bool {
        if (index >= self.entries.items.len) return false;
        var removed = self.entries.orderedRemove(index);
        removed.deinit(allocator);
        return true;
    }

    pub fn entryMatches(self: *const RecentStore, index: usize, kind: RecentKind, path: []const u8) bool {
        if (index >= self.entries.items.len) return false;
        const entry = self.entries.items[index];
        return entry.kind == kind and std.mem.eql(u8, entry.path, path);
    }

    pub fn removeFirstMatching(self: *RecentStore, allocator: std.mem.Allocator, kind: RecentKind, path: []const u8) bool {
        const index = self.find(kind, path) orelse return false;
        return self.removeAt(allocator, index);
    }

    pub fn loadFromRecentState(self: *RecentStore, allocator: std.mem.Allocator, state: config.RecentRepositoriesState) !void {
        // Persisted JSON belongs to OwnedState; duplicate into RecentStore so
        // the app can outlive the parsed state buffer.
        var next: RecentStore = .{};
        errdefer next.deinit(allocator);

        var index = state.entries.len;
        while (index > 0) {
            index -= 1;
            const entry = state.entries[index];
            switch (entry.kind) {
                .repo => try next.rememberRepo(allocator, entry.path),
                .workspace => try next.rememberWorkspace(allocator, entry.path),
            }
        }

        self.deinit(allocator);
        self.* = next;
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
        self.enforceCap(allocator);
    }

    fn rememberWorkspaceDiscovery(
        self: *RecentStore,
        allocator: std.mem.Allocator,
        workspace: @FieldType(repo_discovery.DiscoveryResult, "workspace"),
    ) !void {
        const repo_path = if (workspace.repos.len > 0) workspace.repos[0].canonical_root else "";
        var workspace_owned: ?[]u8 = null;
        errdefer if (workspace_owned) |path| allocator.free(path);
        var repo_owned: ?[]u8 = null;
        errdefer if (repo_owned) |path| allocator.free(path);

        if (workspace.current_root.len > 0 and self.find(.workspace, workspace.current_root) == null) {
            workspace_owned = try allocator.dupe(u8, workspace.current_root);
        }
        if (repo_path.len > 0 and self.find(.repo, repo_path) == null) {
            repo_owned = try allocator.dupe(u8, repo_path);
        }

        const additional = @as(usize, @intFromBool(workspace_owned != null)) + @as(usize, @intFromBool(repo_owned != null));
        try self.entries.ensureUnusedCapacity(allocator, additional);
        self.rememberPrepared(.workspace, workspace.current_root, &workspace_owned);
        self.rememberPrepared(.repo, repo_path, &repo_owned);
        self.enforceCap(allocator);
    }

    fn rememberPrepared(
        self: *RecentStore,
        kind: RecentKind,
        path: []const u8,
        owned_path: *?[]u8,
    ) void {
        if (path.len == 0) return;
        if (self.find(kind, path)) |index| {
            if (index == 0) return;
            const entry = self.entries.orderedRemove(index);
            self.entries.insertAssumeCapacity(0, entry);
            return;
        }
        const owned = owned_path.* orelse unreachable;
        owned_path.* = null;
        self.entries.insertAssumeCapacity(0, .{ .kind = kind, .path = owned });
    }

    fn clone(self: *const RecentStore, allocator: std.mem.Allocator) !RecentStore {
        var next: RecentStore = .{};
        errdefer next.deinit(allocator);
        try next.entries.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            const path = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(path);
            next.entries.appendAssumeCapacity(.{ .kind = entry.kind, .path = path });
        }
        return next;
    }

    fn enforceCap(self: *RecentStore, allocator: std.mem.Allocator) void {
        while (self.entries.items.len > max_recent_entries) {
            var removed = self.entries.pop().?;
            removed.deinit(allocator);
        }
    }

    fn find(self: *const RecentStore, kind: RecentKind, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.kind == kind and std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }
};

pub fn writeRecentRepositoriesJson(store: *const RecentStore, stringify: *std.json.Stringify) !void {
    try stringify.beginObject();
    try stringify.objectField("entries");
    try stringify.beginArray();
    // Defensive only: remember() keeps the store capped at runtime.
    const len = @min(store.entries.items.len, max_recent_entries);
    for (store.entries.items[0..len]) |entry| {
        try stringify.beginObject();
        try stringify.objectField("kind");
        try stringify.write(recentKindName(entry.kind));
        try stringify.objectField("path");
        try stringify.write(entry.path);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
}

fn recentKindName(kind: RecentKind) []const u8 {
    return switch (kind) {
        .repo => "repo",
        .workspace => "workspace",
    };
}

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

    var workspace_path = "/tmp/work".*;
    var repo_path = "/tmp/work/repo".*;
    var repos = [_]repo_discovery.RepoEntry{.{
        .label = "repo",
        .display_path = "repo",
        .canonical_root = &repo_path,
    }};
    const discovery: repo_discovery.DiscoveryResult = .{ .workspace = .{
        .current_root = &workspace_path,
        .repos = &repos,
    } };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, store.rememberDiscovery(failing.allocator(), discovery));
    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try std.testing.expectEqualStrings("/tmp/one", store.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/two", store.entries.items[1].path);

    try store.rememberDiscovery(allocator, discovery);
    try store.rememberDiscovery(allocator, discovery);
    try std.testing.expectEqual(@as(usize, 4), store.entries.items.len);
    try std.testing.expectEqual(RecentKind.repo, store.entries.items[0].kind);
    try std.testing.expectEqual(RecentKind.workspace, store.entries.items[1].kind);
    try std.testing.expectEqualStrings("/tmp/one", store.entries.items[2].path);
    try std.testing.expectEqualStrings("/tmp/two", store.entries.items[3].path);

    @memset(&workspace_path, 'x');
    @memset(&repo_path, 'x');
    try std.testing.expectEqualStrings("/tmp/work/repo", store.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/work", store.entries.items[1].path);
}

test "RecentStore loads persisted recent entries" {
    const allocator = std.testing.allocator;
    var store: RecentStore = .{};
    defer store.deinit(allocator);

    var parsed_arena: std.heap.ArenaAllocator = .init(allocator);
    const parsed_allocator = parsed_arena.allocator();
    const workspace_path = try parsed_allocator.dupe(u8, "/tmp/work");
    const repo_path = try parsed_allocator.dupe(u8, "/tmp/work/repo");

    try store.loadFromRecentState(allocator, .{ .entries = &.{
        .{ .kind = .workspace, .path = workspace_path },
        .{ .kind = .repo, .path = repo_path },
    } });
    parsed_arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try std.testing.expectEqual(RecentKind.workspace, store.entries.items[0].kind);
    try std.testing.expectEqualStrings("/tmp/work", store.entries.items[0].path);
    try std.testing.expectEqual(RecentKind.repo, store.entries.items[1].kind);
    try std.testing.expectEqualStrings("/tmp/work/repo", store.entries.items[1].path);
}

test "RecentStore caps remembered entries" {
    const allocator = std.testing.allocator;
    var store: RecentStore = .{};
    defer store.deinit(allocator);

    var path_buf: [64]u8 = undefined;
    for (0..max_recent_entries + 3) |index| {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/repo-{d}", .{index});
        try store.rememberRepo(allocator, path);
    }

    try std.testing.expectEqual(@as(usize, max_recent_entries), store.entries.items.len);
    try std.testing.expectEqualStrings("/tmp/repo-34", store.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/repo-3", store.entries.items[store.entries.items.len - 1].path);

    var repos = [_]repo_discovery.RepoEntry{.{
        .label = "existing-tail",
        .display_path = "existing-tail",
        .canonical_root = "/tmp/repo-3",
    }};
    try store.rememberDiscovery(allocator, .{ .workspace = .{
        .current_root = "/tmp/workspace",
        .repos = &repos,
    } });
    try std.testing.expectEqual(@as(usize, max_recent_entries), store.entries.items.len);
    try std.testing.expectEqualStrings("/tmp/repo-3", store.entries.items[0].path);
    try std.testing.expectEqualStrings("/tmp/workspace", store.entries.items[1].path);
}

test "RecentStore removes entries by index and matching identity" {
    const allocator = std.testing.allocator;
    var store: RecentStore = .{};
    defer store.deinit(allocator);

    try store.rememberRepo(allocator, "/tmp/one");
    try store.rememberWorkspace(allocator, "/tmp/work");
    try store.rememberRepo(allocator, "/tmp/two");

    try std.testing.expect(store.entryMatches(1, .workspace, "/tmp/work"));
    try std.testing.expect(!store.entryMatches(1, .repo, "/tmp/work"));
    try std.testing.expect(!store.entryMatches(9, .repo, "/tmp/work"));

    try std.testing.expect(store.removeFirstMatching(allocator, .workspace, "/tmp/work"));
    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try std.testing.expect(!store.removeFirstMatching(allocator, .workspace, "/tmp/work"));

    try std.testing.expect(store.removeAt(allocator, 0));
    try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try std.testing.expect(!store.removeAt(allocator, 9));
}

test "writeRecentRepositoriesJson writes recent entries only" {
    const allocator = std.testing.allocator;
    var store: RecentStore = .{};
    defer store.deinit(allocator);
    try store.rememberWorkspace(allocator, "/tmp/work");
    try store.rememberRepo(allocator, "/tmp/work/repo");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    try writeRecentRepositoriesJson(&store, &stringify);

    try std.testing.expectEqualStrings(
        "{\"entries\":[{\"kind\":\"repo\",\"path\":\"/tmp/work/repo\"},{\"kind\":\"workspace\",\"path\":\"/tmp/work\"}]}",
        out.written(),
    );
}
