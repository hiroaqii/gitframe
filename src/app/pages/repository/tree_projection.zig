//! Typed Repository root/manifest projection and cursor restoration.
//!
//! The manifest tree deliberately contains only repository-relative entries.
//! This page-local facade gives the repository boundary a real navigation
//! target without inventing an empty-path manifest node. It also converts the
//! transient visible cursor into a byte-exact typed identity while both tree
//! generations are alive, so reload never restores by a stale visible index.

const std = @import("std");
const repository_tree = @import("../../../repository/tree.zig");

pub const RootDisclosure = enum {
    expanded,
    collapsed,

    pub fn toggled(self: RootDisclosure) RootDisclosure {
        return if (self == .expanded) .collapsed else .expanded;
    }

    pub fn glyph(self: RootDisclosure) []const u8 {
        return if (self == .expanded) "▾ " else "▸ ";
    }
};

/// A target is meaningful only with the accepted manifest tree from which it
/// was projected. `repo_root` is page-owned and never aliases manifest index 0.
pub const Target = union(enum) {
    repo_root,
    manifest_node: usize,
};

pub const ManifestIdentity = struct {
    kind: repository_tree.Kind,
    path: []const u8,
};

/// Borrowed reload identity. Callers capture it before replacing a manifest
/// owner and resolve it while that predecessor is still alive.
pub const CursorIdentity = union(enum) {
    repo_root,
    manifest_node: ManifestIdentity,
};

pub const State = struct {
    root_disclosure: RootDisclosure = .expanded,

    pub fn visibleLen(self: State, tree: *const repository_tree.Tree) usize {
        return 1 + if (self.root_disclosure == .expanded) tree.visible_len else 0;
    }

    pub fn targetAt(self: State, tree: *const repository_tree.Tree, visible_index: usize) ?Target {
        if (visible_index == 0) return .repo_root;
        if (self.root_disclosure == .collapsed) return null;
        const manifest_visible_index = visible_index - 1;
        if (manifest_visible_index >= tree.visible_len) return null;
        return .{ .manifest_node = tree.visible[manifest_visible_index] };
    }

    /// Captures only a real projected target. Invalid or stale numeric cursors
    /// remain distinguishable from an intentional repository-root selection;
    /// the page lifecycle owner decides how to clamp or fall back.
    pub fn cursorIdentity(self: State, tree: *const repository_tree.Tree, visible_index: usize) ?CursorIdentity {
        return switch (self.targetAt(tree, visible_index) orelse return null) {
            .repo_root => .repo_root,
            .manifest_node => |node_index| .{ .manifest_node = .{
                .kind = tree.nodes[node_index].kind,
                .path = tree.nodes[node_index].path,
            } },
        };
    }

    pub fn visibleIndexForTarget(self: State, tree: *const repository_tree.Tree, target: Target) ?usize {
        return switch (target) {
            .repo_root => 0,
            .manifest_node => |node_index| self.visibleIndexForManifestNode(tree, node_index),
        };
    }

    pub fn cursorForIdentity(
        self: State,
        tree: *const repository_tree.Tree,
        visibility: repository_tree.Visibility,
        identity: CursorIdentity,
    ) usize {
        if (self.root_disclosure == .collapsed) return 0;
        return switch (identity) {
            .repo_root => 0,
            .manifest_node => |manifest_identity| visibleCursorForIdentity(
                tree,
                visibility,
                manifest_identity,
            ) orelse 0,
        };
    }

    pub fn toggleTarget(
        self: *State,
        tree: *repository_tree.Tree,
        visibility: repository_tree.Visibility,
        target: Target,
    ) bool {
        return switch (target) {
            .repo_root => blk: {
                self.root_disclosure = self.root_disclosure.toggled();
                break :blk true;
            },
            .manifest_node => |node_index| blk: {
                const visible_index = underlyingVisibleIndex(tree, node_index) orelse break :blk false;
                break :blk tree.toggleVisibleFor(visible_index, visibility);
            },
        };
    }

    pub fn revealManifestNode(
        self: *State,
        tree: *repository_tree.Tree,
        visibility: repository_tree.Visibility,
        node_index: usize,
    ) ?usize {
        if (node_index >= tree.nodes.len or !eligible(tree.nodes[node_index], visibility)) return null;
        const manifest_visible_index = tree.revealNodeFor(node_index, visibility) orelse return null;
        self.root_disclosure = .expanded;
        return manifest_visible_index + 1;
    }

    fn visibleIndexForManifestNode(self: State, tree: *const repository_tree.Tree, node_index: usize) ?usize {
        if (self.root_disclosure == .collapsed) return null;
        const visible_index = underlyingVisibleIndex(tree, node_index) orelse return null;
        return visible_index + 1;
    }
};

fn findExactNode(tree: *const repository_tree.Tree, identity: ManifestIdentity) ?usize {
    for (tree.nodes, 0..) |node, node_index| {
        if (node.kind == identity.kind and std.mem.eql(u8, node.path, identity.path)) return node_index;
    }
    return null;
}

fn underlyingVisibleIndex(tree: *const repository_tree.Tree, node_index: usize) ?usize {
    for (tree.visibleNodes(), 0..) |visible_node, visible_index| {
        if (visible_node == node_index) return visible_index;
    }
    return null;
}

/// Resolves an exact visible node or its deepest visible directory ancestor in
/// one projection scan. This keeps reload restoration linear even for legal
/// 64-KiB-deep paths and large manifests.
fn visibleCursorForIdentity(
    tree: *const repository_tree.Tree,
    visibility: repository_tree.Visibility,
    identity: ManifestIdentity,
) ?usize {
    const exact_node_index = findExactNode(tree, identity);
    var best_path_len: usize = 0;
    var best_cursor: ?usize = null;
    for (tree.visibleNodes(), 0..) |node_index, manifest_visible_index| {
        const node = tree.nodes[node_index];
        if (exact_node_index != null and
            node_index == exact_node_index.? and
            eligible(node, visibility))
        {
            return manifest_visible_index + 1;
        }
        if (node.kind != .directory or !eligible(node, visibility)) continue;
        if (!isStrictPathAncestor(node.path, identity.path) or node.path.len <= best_path_len) continue;
        best_path_len = node.path.len;
        best_cursor = manifest_visible_index + 1;
    }
    return best_cursor;
}

fn eligible(node: repository_tree.Node, visibility: repository_tree.Visibility) bool {
    return visibility == .all or node.subtree_has_change;
}

fn isStrictPathAncestor(candidate: []const u8, path: []const u8) bool {
    return candidate.len < path.len and
        std.mem.startsWith(u8, path, candidate) and
        path[candidate.len] == '/';
}

fn treeForTest(bytes: []const u8) !struct {
    document: @import("../../../repository/manifest.zig").Document,
    tree: repository_tree.Tree,
} {
    const manifest = @import("../../../repository/manifest.zig");
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    const tree = try repository_tree.Tree.build(std.testing.allocator, &document);
    return .{ .document = document, .tree = tree };
}

test "Repository typed projection maps root separately from manifest rows" {
    var fixture = try treeForTest("README.md\x00src/main.zig\x00");
    defer fixture.tree.deinit(std.testing.allocator);
    defer fixture.document.deinit(std.testing.allocator);
    var projection: State = .{};

    try std.testing.expectEqual(fixture.tree.visible_len + 1, projection.visibleLen(&fixture.tree));
    try std.testing.expectEqual(Target.repo_root, projection.targetAt(&fixture.tree, 0).?);
    try std.testing.expectEqual(Target{ .manifest_node = fixture.tree.visible[0] }, projection.targetAt(&fixture.tree, 1).?);
    try std.testing.expectEqual(CursorIdentity.repo_root, projection.cursorIdentity(&fixture.tree, 0).?);
    try std.testing.expect(projection.cursorIdentity(&fixture.tree, projection.visibleLen(&fixture.tree)) == null);

    try std.testing.expect(projection.toggleTarget(&fixture.tree, .all, .repo_root));
    try std.testing.expectEqual(RootDisclosure.collapsed, projection.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), projection.visibleLen(&fixture.tree));
    try std.testing.expect(projection.targetAt(&fixture.tree, 1) == null);
    try std.testing.expect(projection.cursorIdentity(&fixture.tree, 1) == null);

    try std.testing.expect(projection.toggleTarget(&fixture.tree, .all, .repo_root));
    const src_node = fixture.tree.nodeIndexForPath("src", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(projection.toggleTarget(&fixture.tree, .all, .{ .manifest_node = src_node }));
    try std.testing.expect(!fixture.tree.nodes[src_node].expanded);
    try std.testing.expectEqual(fixture.tree.visible_len + 1, projection.visibleLen(&fixture.tree));
}

test "Repository typed cursor restores exact identity then nearest visible ancestor" {
    var fixture = try treeForTest("a/kept.zig\x00a/nested/current.zig\x00other.zig\x00");
    defer fixture.tree.deinit(std.testing.allocator);
    defer fixture.document.deinit(std.testing.allocator);
    const projection: State = .{};

    const nested = fixture.tree.nodeIndexForPath("a/nested", .all) orelse return error.ExpectedDirectory;
    const exact_identity = CursorIdentity{ .manifest_node = .{
        .kind = .directory,
        .path = "a/nested",
    } };
    const exact_cursor = projection.cursorForIdentity(&fixture.tree, .all, exact_identity);
    try std.testing.expectEqual(Target{ .manifest_node = nested }, projection.targetAt(&fixture.tree, exact_cursor).?);

    const fallback_cursor = projection.cursorForIdentity(&fixture.tree, .all, .{ .manifest_node = .{
        .kind = .file,
        .path = "a/removed/path.zig",
    } });
    const fallback_target = projection.targetAt(&fixture.tree, fallback_cursor).?;
    try std.testing.expectEqualStrings("a", fixture.tree.nodes[fallback_target.manifest_node].path);

    var collapsed = projection;
    collapsed.root_disclosure = .collapsed;
    try std.testing.expectEqual(@as(usize, 0), collapsed.cursorForIdentity(&fixture.tree, .all, exact_identity));
}

test "Repository typed cursor restoration is byte exact kind aware and Changed-aware" {
    const change_index = @import("../../../repository/change_index.zig");
    var fixture = try treeForTest("dir/clean-\xff.zig\x00dir/changed.zig\x00");
    defer fixture.tree.deinit(std.testing.allocator);
    defer fixture.document.deinit(std.testing.allocator);
    const projection: State = .{};

    const clean_node = fixture.tree.nodeIndexForPath("dir/clean-\xff.zig", .all) orelse return error.ExpectedFile;
    const exact_cursor = projection.cursorForIdentity(&fixture.tree, .all, .{ .manifest_node = .{
        .kind = .file,
        .path = "dir/clean-\xff.zig",
    } });
    try std.testing.expectEqual(Target{ .manifest_node = clean_node }, projection.targetAt(&fixture.tree, exact_cursor).?);

    var changes = try change_index.parseOwned(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, " M dir/changed.zig\x00"),
    );
    defer changes.deinit(std.testing.allocator);
    _ = fixture.tree.applyChangeIndex(&changes);
    fixture.tree.rebuildVisibleFor(.changed);

    const cursor = projection.cursorForIdentity(&fixture.tree, .changed, .{ .manifest_node = .{
        .kind = .file,
        .path = "dir/clean-\xff.zig",
    } });
    const target = projection.targetAt(&fixture.tree, cursor).?;
    try std.testing.expectEqualStrings("dir", fixture.tree.nodes[target.manifest_node].path);
}

test "Repository typed cursor does not treat same-path kind change as exact" {
    var fixture = try treeForTest("node/child.zig\x00");
    defer fixture.tree.deinit(std.testing.allocator);
    defer fixture.document.deinit(std.testing.allocator);
    const projection: State = .{};

    const cursor = projection.cursorForIdentity(&fixture.tree, .all, .{ .manifest_node = .{
        .kind = .file,
        .path = "node",
    } });
    try std.testing.expectEqual(Target.repo_root, projection.targetAt(&fixture.tree, cursor).?);
}

test "Repository explicit reveal expands both root and manifest ancestors" {
    var fixture = try treeForTest("a/b/file.zig\x00");
    defer fixture.tree.deinit(std.testing.allocator);
    defer fixture.document.deinit(std.testing.allocator);
    var projection: State = .{ .root_disclosure = .collapsed };
    const a_node = fixture.tree.nodeIndexForPath("a", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(fixture.tree.toggleVisibleFor(fixture.tree.visibleIndexForPath("a").?, .all));
    try std.testing.expect(!fixture.tree.nodes[a_node].expanded);
    const file_node = fixture.tree.nodeIndexForPath("a/b/file.zig", .all) orelse return error.ExpectedFile;

    const cursor = projection.revealManifestNode(&fixture.tree, .all, file_node) orelse return error.ExpectedVisibleFile;
    try std.testing.expectEqual(RootDisclosure.expanded, projection.root_disclosure);
    try std.testing.expect(fixture.tree.nodes[a_node].expanded);
    try std.testing.expectEqual(Target{ .manifest_node = file_node }, projection.targetAt(&fixture.tree, cursor).?);
}
