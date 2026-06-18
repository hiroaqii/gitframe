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
