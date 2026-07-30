const std = @import("std");
const change_index = @import("change_index.zig");
const manifest = @import("manifest.zig");

pub const max_nodes: usize = 400_000;
pub const aggregate_allocation_limit: usize = 128 * 1024 * 1024;
const restoration_index_reserve: usize = max_nodes * 3 * @sizeOf(usize);

pub const Kind = enum { directory, file };

/// Selects which raw manifest nodes participate in the current visible tree.
/// Filtering is a projection only: collapse state remains owned by every
/// directory node and survives switching between All and Changed views.
pub const Visibility = enum { all, changed };

/// Compact preorder node. Every string is a slice into the owning manifest;
/// directory paths are borrowed prefixes, never separately copied full paths.
pub const Node = struct {
    kind: Kind,
    parent: ?usize,
    path: []const u8,
    name: []const u8,
    depth: usize,
    expanded: bool = false,
    file_change: ?change_index.Kind = null,
    /// Cached descendant predicate for the Changed-only visible projection.
    /// Directories keep their normal color; this only controls reachability.
    subtree_has_change: bool = false,
};

pub const BuildError = error{
    OutOfMemory,
    TooManyNodes,
    MaterializationTooLarge,
};

pub const Tree = struct {
    nodes: []Node = &.{},
    visible: []usize = &.{},
    visible_len: usize = 0,

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        allocator.free(self.visible);
        allocator.free(self.nodes);
        self.* = .{};
    }

    pub fn build(allocator: std.mem.Allocator, document: *const manifest.Document) BuildError!Tree {
        const shape = try measure(document.paths);
        if (shape.node_count > max_nodes) return error.TooManyNodes;
        const allocation_bytes = try materializationBytes(document, shape);
        if (allocation_bytes > aggregate_allocation_limit) return error.MaterializationTooLarge;

        const nodes = try allocator.alloc(Node, shape.node_count);
        errdefer allocator.free(nodes);
        const visible = try allocator.alloc(usize, shape.node_count);
        errdefer allocator.free(visible);
        const directory_stack = try allocator.alloc(usize, shape.max_directory_depth);
        defer allocator.free(directory_stack);

        var node_index: usize = 0;
        var previous: []const u8 = "";
        for (document.paths) |path| {
            const common = commonDirectoryDepth(previous, path);
            var component_start: usize = 0;
            var directory_depth: usize = 0;
            for (path, 0..) |byte, byte_index| {
                if (byte != '/') continue;
                if (directory_depth >= common) {
                    nodes[node_index] = .{
                        .kind = .directory,
                        .parent = if (directory_depth == 0) null else directory_stack[directory_depth - 1],
                        .path = path[0..byte_index],
                        .name = path[component_start..byte_index],
                        .depth = directory_depth,
                    };
                    directory_stack[directory_depth] = node_index;
                    node_index += 1;
                }
                component_start = byte_index + 1;
                directory_depth += 1;
            }
            nodes[node_index] = .{
                .kind = .file,
                .parent = if (directory_depth == 0) null else directory_stack[directory_depth - 1],
                .path = path,
                .name = path[component_start..],
                .depth = directory_depth,
            };
            node_index += 1;
            previous = path;
        }
        std.debug.assert(node_index == nodes.len);

        var result = Tree{ .nodes = nodes, .visible = visible };
        result.rebuildVisible();
        return result;
    }

    /// Restores collapse state and resolves sticky selection while both tree
    /// generations are alive. Temporary indexes are raw-path sorted, so this
    /// does not assume preorder happens to be globally byte sorted.
    pub fn restoreStateFrom(
        self: *Tree,
        allocator: std.mem.Allocator,
        previous: *const Tree,
        previous_selected: ?[]const u8,
    ) BuildError!?[]const u8 {
        const old_directories = try sortedIndices(allocator, previous, .directory);
        defer allocator.free(old_directories);
        const new_directories = try sortedIndices(allocator, self, .directory);
        defer allocator.free(new_directories);
        const new_files = try sortedIndices(allocator, self, .file);
        defer allocator.free(new_files);

        var old_cursor: usize = 0;
        var new_cursor: usize = 0;
        while (old_cursor < old_directories.len and new_cursor < new_directories.len) {
            const old_node = previous.nodes[old_directories[old_cursor]];
            const new_node = &self.nodes[new_directories[new_cursor]];
            switch (std.mem.order(u8, old_node.path, new_node.path)) {
                .lt => old_cursor += 1,
                .gt => new_cursor += 1,
                .eq => {
                    new_node.expanded = old_node.expanded;
                    old_cursor += 1;
                    new_cursor += 1;
                },
            }
        }
        self.rebuildVisible();

        const selected = previous_selected orelse return self.firstFilePath();
        if (findRawPath(self, new_files, selected)) |path| return path;

        var old_selected_index: ?usize = null;
        for (previous.nodes, 0..) |node, index| {
            if (node.kind == .file and std.mem.eql(u8, node.path, selected)) {
                old_selected_index = index;
                break;
            }
        }
        const selected_index = old_selected_index orelse return self.firstFilePath();
        for (previous.nodes[selected_index + 1 ..]) |node| {
            if (node.kind != .file) continue;
            if (findRawPath(self, new_files, node.path)) |path| return path;
        }
        var index = selected_index;
        while (index > 0) {
            index -= 1;
            const node = previous.nodes[index];
            if (node.kind != .file) continue;
            if (findRawPath(self, new_files, node.path)) |path| return path;
        }
        return self.firstFilePath();
    }

    pub fn rebuildVisible(self: *Tree) void {
        self.rebuildVisibleFor(.all);
    }

    pub fn rebuildVisibleFor(self: *Tree, visibility: Visibility) void {
        var length: usize = 0;
        var hidden_below_depth: ?usize = null;
        for (self.nodes, 0..) |node, index| {
            if (visibility == .changed and !node.subtree_has_change) continue;
            if (hidden_below_depth) |depth| {
                if (node.depth > depth) continue;
                hidden_below_depth = null;
            }
            self.visible[length] = index;
            length += 1;
            if (node.kind == .directory and !node.expanded) hidden_below_depth = node.depth;
        }
        self.visible_len = length;
    }

    pub fn visibleNodes(self: *const Tree) []const usize {
        return self.visible[0..self.visible_len];
    }

    pub fn toggleVisibleFor(self: *Tree, visible_index: usize, visibility: Visibility) bool {
        if (visible_index >= self.visible_len) return false;
        const node = &self.nodes[self.visible[visible_index]];
        if (node.kind != .directory) return false;
        node.expanded = !node.expanded;
        self.rebuildVisibleFor(visibility);
        return true;
    }

    /// Returns every directory to the minimum tree shape. Expansion is raw
    /// tree state shared by All and Changed projections, so even directories
    /// hidden from the current visibility must be closed.
    pub fn collapseAllFor(self: *Tree, visibility: Visibility) bool {
        var changed = false;
        for (self.nodes) |*node| {
            if (node.kind != .directory or !node.expanded) continue;
            node.expanded = false;
            changed = true;
        }
        if (changed) self.rebuildVisibleFor(visibility);
        return changed;
    }

    pub fn firstFilePath(self: *const Tree) ?[]const u8 {
        for (self.nodes) |node| if (node.kind == .file) return node.path;
        return null;
    }

    pub fn firstFilePathFor(self: *const Tree, visibility: Visibility) ?[]const u8 {
        for (self.nodes) |node| {
            if (node.kind != .file) continue;
            if (visibility == .changed and node.file_change == null) continue;
            return node.path;
        }
        return null;
    }

    pub fn filePath(self: *const Tree, path: []const u8, visibility: Visibility) ?[]const u8 {
        for (self.nodes) |node| {
            if (node.kind != .file or !std.mem.eql(u8, node.path, path)) continue;
            if (visibility == .changed and node.file_change == null) return null;
            return node.path;
        }
        return null;
    }

    pub fn nodeIndexForPath(self: *const Tree, path: []const u8, visibility: Visibility) ?usize {
        for (self.nodes, 0..) |node, index| {
            if (!std.mem.eql(u8, node.path, path)) continue;
            if (visibility == .changed and !node.subtree_has_change) return null;
            return index;
        }
        return null;
    }

    pub fn revealNodeFor(self: *Tree, node_index: usize, visibility: Visibility) ?usize {
        if (node_index >= self.nodes.len) return null;
        if (visibility == .changed and !self.nodes[node_index].subtree_has_change) return null;
        var parent = self.nodes[node_index].parent;
        while (parent) |index| {
            self.nodes[index].expanded = true;
            parent = self.nodes[index].parent;
        }
        self.rebuildVisibleFor(visibility);
        for (self.visibleNodes(), 0..) |visible_node, visible_index| {
            if (visible_node == node_index) return visible_index;
        }
        return null;
    }

    /// Projects byte-exact status paths onto current manifest files and caches
    /// the descendant predicate consumed by Changed visibility. Deleted paths
    /// cannot create synthetic tree nodes.
    pub fn applyChangeIndex(self: *Tree, index: *const change_index.Index) bool {
        var changed = false;
        for (self.nodes) |*node| {
            const next: ?change_index.Kind = if (node.kind == .file) index.kindForPath(node.path) else null;
            // Directory predicates are derived solely from file classifications
            // below. Comparing their transient reset state would make an
            // identical final projection report a false-positive redraw.
            changed = changed or node.file_change != next;
            node.file_change = next;
            node.subtree_has_change = next != null;
        }
        var cursor = self.nodes.len;
        while (cursor > 0) {
            cursor -= 1;
            const node = &self.nodes[cursor];
            if (!node.subtree_has_change) continue;
            if (node.parent) |parent| self.nodes[parent].subtree_has_change = true;
        }
        return changed;
    }

    pub fn clearChangeIndex(self: *Tree) bool {
        var changed = false;
        for (self.nodes) |*node| {
            changed = changed or node.file_change != null;
            node.file_change = null;
            node.subtree_has_change = false;
        }
        return changed;
    }
};

const Shape = struct { node_count: usize, max_directory_depth: usize };

fn measure(paths: []const []const u8) BuildError!Shape {
    var node_count: usize = 0;
    var max_depth: usize = 0;
    var previous: []const u8 = "";
    for (paths) |path| {
        const directory_depth = std.mem.count(u8, path, "/");
        const common = commonDirectoryDepth(previous, path);
        node_count = std.math.add(usize, node_count, directory_depth - common + 1) catch return error.TooManyNodes;
        if (node_count > max_nodes) return error.TooManyNodes;
        max_depth = @max(max_depth, directory_depth);
        previous = path;
    }
    return .{ .node_count = node_count, .max_directory_depth = max_depth };
}

fn materializationBytes(document: *const manifest.Document, shape: Shape) BuildError!usize {
    var total = document.bytes.len;
    total = std.math.add(usize, total, std.math.mul(usize, document.paths.len, @sizeOf([]const u8)) catch return error.MaterializationTooLarge) catch return error.MaterializationTooLarge;
    total = std.math.add(usize, total, std.math.mul(usize, shape.node_count, @sizeOf(Node)) catch return error.MaterializationTooLarge) catch return error.MaterializationTooLarge;
    total = std.math.add(usize, total, std.math.mul(usize, shape.node_count, @sizeOf(usize)) catch return error.MaterializationTooLarge) catch return error.MaterializationTooLarge;
    total = std.math.add(usize, total, std.math.mul(usize, shape.max_directory_depth, @sizeOf(usize)) catch return error.MaterializationTooLarge) catch return error.MaterializationTooLarge;
    total = std.math.add(usize, total, restoration_index_reserve) catch return error.MaterializationTooLarge;
    return total;
}

test "repository tree declared maximum fits aggregate allocation ceiling" {
    const worst_case = manifest.max_bytes +
        manifest.max_paths * @sizeOf([]const u8) +
        max_nodes * @sizeOf(Node) +
        max_nodes * @sizeOf(usize) +
        max_nodes * @sizeOf(usize) +
        restoration_index_reserve;
    try std.testing.expect(worst_case <= aggregate_allocation_limit);
}

fn commonDirectoryDepth(previous: []const u8, current: []const u8) usize {
    var common: usize = 0;
    for (current, 0..) |byte, index| {
        if (byte != '/') continue;
        if (index >= previous.len or previous[index] != '/' or !std.mem.eql(u8, current[0..index], previous[0..index])) break;
        common += 1;
    }
    return common;
}

fn sortedIndices(allocator: std.mem.Allocator, tree: *const Tree, kind: Kind) BuildError![]usize {
    var count: usize = 0;
    for (tree.nodes) |node| if (node.kind == kind) {
        count += 1;
    };
    const indices = try allocator.alloc(usize, count);
    errdefer allocator.free(indices);
    var cursor: usize = 0;
    for (tree.nodes, 0..) |node, index| if (node.kind == kind) {
        indices[cursor] = index;
        cursor += 1;
    };
    std.mem.sort(usize, indices, tree, rawNodeIndexLessThan);
    return indices;
}

fn rawNodeIndexLessThan(tree: *const Tree, left: usize, right: usize) bool {
    return std.mem.order(u8, tree.nodes[left].path, tree.nodes[right].path) == .lt;
}

fn findRawPath(tree: *const Tree, sorted_indices: []const usize, path: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high = sorted_indices.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = tree.nodes[sorted_indices[middle]].path;
        switch (std.mem.order(u8, candidate, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return candidate,
        }
    }
    return null;
}

fn documentForTest(bytes: []const u8) !manifest.Document {
    return manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
}

test "repository minimum tree disclosure builds only top-level entries and toggles children" {
    var document = try documentForTest("README.md\x00src/app.zig\x00src/main.zig\x00");
    defer document.deinit(std.testing.allocator);
    var tree = try Tree.build(std.testing.allocator, &document);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), tree.nodes.len);
    try std.testing.expectEqual(Kind.directory, tree.nodes[0].kind);
    try std.testing.expectEqualStrings("src", tree.nodes[0].path);
    try std.testing.expect(!tree.nodes[0].expanded);
    try std.testing.expectEqual(@as(usize, 2), tree.visible_len);
    try std.testing.expect(tree.toggleVisibleFor(0, .all));
    try std.testing.expectEqual(@as(usize, 4), tree.visible_len);
    try std.testing.expect(tree.collapseAllFor(.all));
    try std.testing.expectEqual(@as(usize, 2), tree.visible_len);
    try std.testing.expect(!tree.collapseAllFor(.all));
}

test "repository minimum tree disclosure reveals a file below collapsed ancestors only" {
    var document = try documentForTest("a/b/file.zig\x00other/nested/file.zig\x00root.zig\x00");
    defer document.deinit(std.testing.allocator);
    var tree = try Tree.build(std.testing.allocator, &document);
    defer tree.deinit(std.testing.allocator);
    const file_index = tree.nodeIndexForPath("a/b/file.zig", .all) orelse return error.ExpectedFile;
    try std.testing.expect(std.mem.indexOfScalar(usize, tree.visibleNodes(), file_index) == null);
    const visible = tree.revealNodeFor(file_index, .all) orelse return error.ExpectedVisibleFile;
    try std.testing.expectEqualStrings("a/b/file.zig", tree.nodes[tree.visible[visible]].path);
    const other = tree.nodeIndexForPath("other", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(!tree.nodes[other].expanded);
    const other_nested = tree.nodeIndexForPath("other/nested", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(std.mem.indexOfScalar(usize, tree.visibleNodes(), other_nested) == null);
}

test "repository minimum tree disclosure restores matching expansion and keeps new directories closed" {
    var first_document = try documentForTest("a/one.zig\x00a/two.zig\x00b/three.zig\x00");
    defer first_document.deinit(std.testing.allocator);
    var first = try Tree.build(std.testing.allocator, &first_document);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.toggleVisibleFor(0, .all));

    var next_document = try documentForTest("a/one.zig\x00a/new.zig\x00b/three.zig\x00c/four.zig\x00");
    defer next_document.deinit(std.testing.allocator);
    var next = try Tree.build(std.testing.allocator, &next_document);
    defer next.deinit(std.testing.allocator);
    const selected = try next.restoreStateFrom(std.testing.allocator, &first, "a/two.zig");

    const a = next.nodeIndexForPath("a", .all) orelse return error.ExpectedDirectory;
    const b = next.nodeIndexForPath("b", .all) orelse return error.ExpectedDirectory;
    const c = next.nodeIndexForPath("c", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(next.nodes[a].expanded);
    try std.testing.expect(!next.nodes[b].expanded);
    try std.testing.expect(!next.nodes[c].expanded);
    try std.testing.expectEqualStrings("b/three.zig", selected.?);
}

test "repository tree orders directory siblings before file siblings" {
    var document = try documentForTest("README.md\x00z-dir/file.zig\x00a-dir/file.zig\x00alpha.txt\x00");
    defer document.deinit(std.testing.allocator);
    var tree = try Tree.build(std.testing.allocator, &document);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a-dir", tree.nodes[0].path);
    try std.testing.expectEqualStrings("a-dir/file.zig", tree.nodes[1].path);
    try std.testing.expectEqualStrings("z-dir", tree.nodes[2].path);
    try std.testing.expectEqualStrings("z-dir/file.zig", tree.nodes[3].path);
    try std.testing.expectEqualStrings("README.md", tree.nodes[4].path);
    try std.testing.expectEqualStrings("alpha.txt", tree.nodes[5].path);
}

test "repository tree restores dash sibling collapse by raw identity" {
    var old_document = try documentForTest("a/f.zig\x00a-b/g.zig\x00");
    defer old_document.deinit(std.testing.allocator);
    var old = try Tree.build(std.testing.allocator, &old_document);
    defer old.deinit(std.testing.allocator);
    const old_a = old.nodeIndexForPath("a", .all) orelse return error.ExpectedDirectory;
    const old_a_visible = std.mem.indexOfScalar(usize, old.visibleNodes(), old_a) orelse
        return error.ExpectedDirectory;
    try std.testing.expect(old.toggleVisibleFor(old_a_visible, .all));

    var new_document = try documentForTest("a/f.zig\x00a-c/g.zig\x00");
    defer new_document.deinit(std.testing.allocator);
    var new = try Tree.build(std.testing.allocator, &new_document);
    defer new.deinit(std.testing.allocator);
    _ = try new.restoreStateFrom(std.testing.allocator, &old, null);

    const a = new.nodeIndexForPath("a", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(new.nodes[a].expanded);
    const a_c = new.nodeIndexForPath("a-c", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(!new.nodes[a_c].expanded);
}

test "repository tree projects exact file changes and changed ancestors" {
    var document = try documentForTest("a/file.zig\x00a/nested/other.zig\x00plain.zig\x00");
    defer document.deinit(std.testing.allocator);
    var tree = try Tree.build(std.testing.allocator, &document);
    defer tree.deinit(std.testing.allocator);
    var index = try change_index.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "?? a/file.zig\x00" ++
        " M a/nested/other.zig\x00" ++
        " M deleted.zig\x00"));
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(tree.applyChangeIndex(&index));
    for (tree.nodes) |node| {
        if (std.mem.eql(u8, node.path, "a/file.zig"))
            try std.testing.expectEqual(change_index.Kind.added, node.file_change.?)
        else if (std.mem.eql(u8, node.path, "a/nested/other.zig"))
            try std.testing.expectEqual(change_index.Kind.modified, node.file_change.?)
        else if (node.kind == .directory and (std.mem.eql(u8, node.path, "a") or std.mem.eql(u8, node.path, "a/nested")))
            try std.testing.expect(node.subtree_has_change)
        else if (std.mem.eql(u8, node.path, "plain.zig"))
            try std.testing.expect(node.file_change == null);
    }
    try std.testing.expect(!tree.applyChangeIndex(&index));
    var same_projection = try change_index.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, " A a/file.zig\x00" ++
        "M  a/nested/other.zig\x00"));
    defer same_projection.deinit(std.testing.allocator);
    try std.testing.expect(!tree.applyChangeIndex(&same_projection));
    try std.testing.expect(tree.clearChangeIndex());
    try std.testing.expect(!tree.clearChangeIndex());
    for (tree.nodes) |node| {
        try std.testing.expect(node.file_change == null);
        try std.testing.expect(!node.subtree_has_change);
    }
}

test "repository tree changed visibility keeps only matching ancestry and collapse state" {
    var document = try documentForTest("a/changed.zig\x00a/clean.zig\x00b/clean.zig\x00root.zig\x00");
    defer document.deinit(std.testing.allocator);
    var tree = try Tree.build(std.testing.allocator, &document);
    defer tree.deinit(std.testing.allocator);
    var index = try change_index.parseOwned(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, " M a/changed.zig\x00"),
    );
    defer index.deinit(std.testing.allocator);
    _ = tree.applyChangeIndex(&index);

    tree.rebuildVisibleFor(.changed);
    try std.testing.expectEqual(@as(usize, 1), tree.visible_len);
    try std.testing.expectEqualStrings("a", tree.nodes[tree.visible[0]].path);
    try std.testing.expect(tree.toggleVisibleFor(0, .changed));
    try std.testing.expectEqual(@as(usize, 2), tree.visible_len);
    try std.testing.expectEqualStrings("a/changed.zig", tree.nodes[tree.visible[1]].path);

    tree.rebuildVisibleFor(.all);
    try std.testing.expect(tree.nodes[0].expanded);
    try std.testing.expectEqual(@as(usize, 5), tree.visible_len);
    try std.testing.expect(tree.toggleVisibleFor(0, .all));
    tree.rebuildVisibleFor(.changed);
    try std.testing.expectEqual(@as(usize, 1), tree.visible_len);
    const changed_index = tree.nodeIndexForPath("a/changed.zig", .changed) orelse return error.ExpectedChangedFile;
    _ = tree.revealNodeFor(changed_index, .changed) orelse return error.ExpectedVisibleFile;
    try std.testing.expect(tree.nodes[0].expanded);
    try std.testing.expectEqualStrings("a/changed.zig", tree.firstFilePathFor(.changed).?);
    try std.testing.expect(tree.filePath("a/clean.zig", .changed) == null);
}

test "repository tree deleted selection follows surviving old order" {
    {
        var old_document = try documentForTest("a.zig\x00b.zig\x00d.zig\x00");
        defer old_document.deinit(std.testing.allocator);
        var old = try Tree.build(std.testing.allocator, &old_document);
        defer old.deinit(std.testing.allocator);
        var new_document = try documentForTest("a.zig\x00c.zig\x00d.zig\x00");
        defer new_document.deinit(std.testing.allocator);
        var new = try Tree.build(std.testing.allocator, &new_document);
        defer new.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("d.zig", (try new.restoreStateFrom(std.testing.allocator, &old, "b.zig")).?);
    }
    {
        var old_document = try documentForTest("a.zig\x00b.zig\x00d.zig\x00e.zig\x00");
        defer old_document.deinit(std.testing.allocator);
        var old = try Tree.build(std.testing.allocator, &old_document);
        defer old.deinit(std.testing.allocator);
        var new_document = try documentForTest("a.zig\x00e.zig\x00");
        defer new_document.deinit(std.testing.allocator);
        var new = try Tree.build(std.testing.allocator, &new_document);
        defer new.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("e.zig", (try new.restoreStateFrom(std.testing.allocator, &old, "b.zig")).?);
    }
    {
        var old_document = try documentForTest("a.zig\x00b.zig\x00");
        defer old_document.deinit(std.testing.allocator);
        var old = try Tree.build(std.testing.allocator, &old_document);
        defer old.deinit(std.testing.allocator);
        var new_document = try documentForTest("a.zig\x00");
        defer new_document.deinit(std.testing.allocator);
        var new = try Tree.build(std.testing.allocator, &new_document);
        defer new.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("a.zig", (try new.restoreStateFrom(std.testing.allocator, &old, "b.zig")).?);
    }
    {
        var old_document = try documentForTest("a.zig\x00b.zig\x00");
        defer old_document.deinit(std.testing.allocator);
        var old = try Tree.build(std.testing.allocator, &old_document);
        defer old.deinit(std.testing.allocator);
        var new_document = try documentForTest("c.zig\x00");
        defer new_document.deinit(std.testing.allocator);
        var new = try Tree.build(std.testing.allocator, &new_document);
        defer new.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("c.zig", (try new.restoreStateFrom(std.testing.allocator, &old, "b.zig")).?);
    }
}
