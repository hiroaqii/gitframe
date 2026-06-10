const std = @import("std");

const diff_parser = @import("diff_parser.zig");

pub const CollapsedSet = std.StringHashMapUnmanaged(void);

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,

    pub fn add(self: *Stats, other: Stats) void {
        self.added += other.added;
        self.removed += other.removed;
    }
};

pub const Node = struct {
    kind: Kind,
    name: []const u8,
    path: []const u8,
    depth: u16,
    stats: Stats = .{},
    file_index: ?usize = null,

    pub const Kind = enum {
        directory,
        file,
    };
};

pub const FileTree = struct {
    nodes: []const Node,

    pub fn selectedNodeIndex(self: FileTree, file_index: usize) ?usize {
        for (self.nodes, 0..) |node, index| {
            if (node.file_index == file_index) return index;
        }
        return null;
    }

    pub fn visibleNodeCount(self: FileTree, collapsed: *const CollapsedSet) usize {
        var count: usize = 0;
        for (self.nodes, 0..) |_, index| {
            if (self.isVisible(index, collapsed)) count += 1;
        }
        return count;
    }

    pub fn visibleNodeAt(self: FileTree, collapsed: *const CollapsedSet, visible_index: usize) ?usize {
        var visible_count: usize = 0;
        for (self.nodes, 0..) |_, index| {
            if (!self.isVisible(index, collapsed)) continue;
            if (visible_count == visible_index) return index;
            visible_count += 1;
        }
        return null;
    }

    pub fn visibleRowOfNode(self: FileTree, collapsed: *const CollapsedSet, node_index: usize) ?usize {
        if (node_index >= self.nodes.len or !self.isVisible(node_index, collapsed)) return null;

        var visible_count: usize = 0;
        for (self.nodes, 0..) |_, index| {
            if (!self.isVisible(index, collapsed)) continue;
            if (index == node_index) return visible_count;
            visible_count += 1;
        }
        return null;
    }

    pub fn nextVisibleNodeIndex(self: FileTree, collapsed: *const CollapsedSet, node_index: usize) ?usize {
        var index = node_index + 1;
        while (index < self.nodes.len) : (index += 1) {
            if (self.isVisible(index, collapsed)) return index;
        }
        return null;
    }

    pub fn previousVisibleNodeIndex(self: FileTree, collapsed: *const CollapsedSet, node_index: usize) ?usize {
        var index = node_index;
        while (index > 0) {
            index -= 1;
            if (self.isVisible(index, collapsed)) return index;
        }
        return null;
    }

    pub fn visibleAncestorOrSelf(self: FileTree, collapsed: *const CollapsedSet, node_index: usize) ?usize {
        if (node_index >= self.nodes.len) return null;
        if (self.isVisible(node_index, collapsed)) return node_index;

        const node = self.nodes[node_index];
        var index = node_index;
        while (index > 0) {
            index -= 1;
            const candidate = self.nodes[index];
            if (candidate.kind != .directory) continue;
            if (candidate.depth >= node.depth) continue;
            if (!isPathAncestor(candidate.path, node.path)) continue;
            if (self.isVisible(index, collapsed)) return index;
        }
        return null;
    }

    pub fn isVisible(self: FileTree, node_index: usize, collapsed: *const CollapsedSet) bool {
        if (node_index >= self.nodes.len) return false;
        return !hasCollapsedAncestor(self.nodes[node_index].path, collapsed);
    }
};

pub fn build(allocator: std.mem.Allocator, document: diff_parser.DiffDocument) !FileTree {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    for (document.files, 0..) |file, file_index| {
        const path = displayPath(file);
        const stats = fileStats(file);

        try ensureDirectoryNodes(allocator, &nodes, path, stats);
        try nodes.append(allocator, .{
            .kind = .file,
            .name = baseName(path),
            .path = path,
            .depth = pathDepth(path),
            .stats = stats,
            .file_index = file_index,
        });
    }

    return .{ .nodes = try nodes.toOwnedSlice(allocator) };
}

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    if (file.new_path) |path| return stripGitPathPrefix(path);
    if (file.old_path) |path| return stripGitPathPrefix(path);
    return file.header;
}

pub fn fileStats(file: diff_parser.FileDiff) Stats {
    var stats: Stats = .{};
    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.kind) {
                .added => stats.added += 1,
                .removed => stats.removed += 1,
                else => {},
            }
        }
    }
    return stats;
}

fn ensureDirectoryNodes(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), path: []const u8, stats: Stats) !void {
    var start: usize = 0;
    var depth: u16 = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        if (slash > start) {
            const dir_path = path[0..slash];
            const dir_index = findDirectory(nodes.items, dir_path) orelse blk: {
                try nodes.append(allocator, .{
                    .kind = .directory,
                    .name = path[start..slash],
                    .path = dir_path,
                    .depth = depth,
                });
                break :blk nodes.items.len - 1;
            };
            nodes.items[dir_index].stats.add(stats);
        }
        start = slash + 1;
        depth += 1;
    }
}

fn findDirectory(nodes: []const Node, path: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (node.kind == .directory and std.mem.eql(u8, node.path, path)) return index;
    }
    return null;
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash + 1 < path.len) return path[slash + 1 ..];
    }
    return path;
}

fn pathDepth(path: []const u8) u16 {
    var depth: u16 = 0;
    for (path) |byte| {
        if (byte == '/') depth += 1;
    }
    return depth;
}

fn stripGitPathPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

pub fn isCollapsed(collapsed: *const CollapsedSet, path: []const u8) bool {
    return collapsed.contains(path);
}

pub fn collapse(allocator: std.mem.Allocator, collapsed: *CollapsedSet, path: []const u8) !void {
    try collapsed.put(allocator, path, {});
}

pub fn expand(collapsed: *CollapsedSet, path: []const u8) void {
    _ = collapsed.remove(path);
}

pub fn toggle(allocator: std.mem.Allocator, collapsed: *CollapsedSet, path: []const u8) !void {
    if (isCollapsed(collapsed, path)) {
        expand(collapsed, path);
    } else {
        try collapse(allocator, collapsed, path);
    }
}

fn hasCollapsedAncestor(path: []const u8, collapsed: *const CollapsedSet) bool {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        if (slash > 0 and collapsed.contains(path[0..slash])) return true;
        start = slash + 1;
    }
    return false;
}

fn isPathAncestor(ancestor: []const u8, path: []const u8) bool {
    return path.len > ancestor.len and
        std.mem.startsWith(u8, path, ancestor) and
        path[ancestor.len] == '/';
}

test "build creates directory and file nodes with aggregate stats" {
    const text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1,2 @@
        \\-old
        \\+new
        \\+added
        \\diff --git a/src/lib/root.zig b/src/lib/root.zig
        \\--- a/src/lib/root.zig
        \\+++ b/src/lib/root.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, text);
    const tree = try build(allocator, document);

    try std.testing.expectEqual(@as(usize, 4), tree.nodes.len);
    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[0].kind);
    try std.testing.expectEqualStrings("src", tree.nodes[0].name);
    try std.testing.expectEqual(@as(usize, 3), tree.nodes[0].stats.added);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes[0].stats.removed);
    try std.testing.expectEqual(Node.Kind.file, tree.nodes[1].kind);
    try std.testing.expectEqualStrings("main.zig", tree.nodes[1].name);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodes[1].file_index);
    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[2].kind);
    try std.testing.expectEqualStrings("lib", tree.nodes[2].name);
    try std.testing.expectEqual(Node.Kind.file, tree.nodes[3].kind);
    try std.testing.expectEqualStrings("root.zig", tree.nodes[3].name);
}

test "selectedNodeIndex maps file index to tree row" {
    const nodes = [_]Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 1, .file_index = 0 },
    };
    const tree = FileTree{ .nodes = &nodes };

    try std.testing.expectEqual(@as(?usize, 1), tree.selectedNodeIndex(0));
    try std.testing.expectEqual(@as(?usize, null), tree.selectedNodeIndex(1));
}

test "collapsed directory hides descendants but remains visible" {
    const nodes = [_]Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 1, .file_index = 0 },
        .{ .kind = .directory, .name = "test", .path = "test", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "test/main.zig", .depth = 1, .file_index = 1 },
    };
    const tree = FileTree{ .nodes = &nodes };
    var collapsed: CollapsedSet = .empty;
    defer collapsed.deinit(std.testing.allocator);

    try collapse(std.testing.allocator, &collapsed, "src");

    try std.testing.expect(tree.isVisible(0, &collapsed));
    try std.testing.expect(!tree.isVisible(1, &collapsed));
    try std.testing.expect(tree.isVisible(2, &collapsed));
    try std.testing.expect(tree.isVisible(3, &collapsed));
    try std.testing.expectEqual(@as(usize, 3), tree.visibleNodeCount(&collapsed));
    try std.testing.expectEqual(@as(?usize, 0), tree.visibleNodeAt(&collapsed, 0));
    try std.testing.expectEqual(@as(?usize, 2), tree.visibleNodeAt(&collapsed, 1));
    try std.testing.expectEqual(@as(?usize, 0), tree.visibleAncestorOrSelf(&collapsed, 1));
}
