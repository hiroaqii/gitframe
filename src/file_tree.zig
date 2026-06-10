const std = @import("std");

const diff_parser = @import("diff_parser.zig");

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
