const std = @import("std");

const context = @import("context.zig");
const diff_file = @import("diff/file.zig");
const diff_parser = @import("diff/parser.zig");
const git_status = @import("git/status.zig");
const path_order = @import("path_key.zig");

pub const CollapsedSet = std.StringHashMapUnmanaged(void);

pub const Stats = diff_file.Stats;
pub const Status = diff_file.Status;

// Build-only dedup index. Keys borrow path slices owned by the parsed diff
// arena and are not stored in the returned FileTree model.
const DirectoryIndex = std.StringHashMapUnmanaged(usize);
const PathKeySet = std.StringHashMapUnmanaged(void);
const StatusIndex = std.StringHashMapUnmanaged(usize);

pub const StagePresence = enum {
    unstaged_only,
    staged_only,
    mixed,
    untracked,
    conflict,
    clean_or_unknown,
};

const RowSource = struct {
    name: []const u8,
    path: []const u8,
    path_key: []const u8,
    stats: Stats = .{},
    status: ?Status = null,
    stage_presence: StagePresence = .clean_or_unknown,
    mode_changed: bool = false,
    target: context.SidebarTarget,
};

/// Session-local file key memory used while rebuilding the sidebar.
///
/// Keys are copied into the App allocator because the source rows usually
/// borrow from a per-load arena. Final display sorting still groups sibling
/// directories before files, so this is a row rebuild aid rather than the
/// visible ordering contract.
pub const StableOrder = struct {
    keys: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *StableOrder, allocator: std.mem.Allocator) void {
        for (self.keys.items) |key| allocator.free(key);
        self.keys.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *StableOrder, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    fn remember(self: *StableOrder, allocator: std.mem.Allocator, rows: []const RowSource) !void {
        for (self.keys.items) |key| allocator.free(key);
        self.keys.clearRetainingCapacity();
        errdefer {
            for (self.keys.items) |key| allocator.free(key);
            self.keys.clearRetainingCapacity();
        }

        for (rows) |row| {
            const key = try allocator.dupe(u8, row.path_key);
            errdefer allocator.free(key);
            try self.keys.append(allocator, key);
        }
    }
};

pub const StableOrderOptions = struct {
    allocator: std.mem.Allocator,
    order: *StableOrder,
};

pub const RootOptions = struct {
    name: []const u8,
};

pub const BuildOptions = struct {
    root: ?RootOptions = null,
    stable_order: ?StableOrderOptions = null,
};

pub const Node = struct {
    kind: Kind,
    name: []const u8,
    path: []const u8,
    path_key: []const u8 = "",
    depth: u16,
    stats: Stats = .{},
    status: ?Status = null,
    stage_presence: StagePresence = .clean_or_unknown,
    mode_changed: bool = false,
    target: context.SidebarTarget = .{ .directory = "" },

    pub const Kind = enum {
        repo_root,
        directory,
        file,
    };

    /// Transitional compatibility for diff-only tree consumers.
    /// TODO: switch remaining callers to target-aware handling, then remove
    /// this accessor.
    pub fn diffFileIndex(self: Node) ?usize {
        return self.target.diffFileIndex();
    }
};

pub const FileTree = struct {
    nodes: []const Node,

    pub fn selectedNodeIndex(self: FileTree, file_index: usize) ?usize {
        for (self.nodes, 0..) |node, index| {
            if (node.diffFileIndex() == file_index) return index;
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

    pub fn parentDirectoryNodeIndex(self: FileTree, node_index: usize) ?usize {
        if (node_index >= self.nodes.len) return null;

        const node = self.nodes[node_index];
        var index = node_index;
        while (index > 0) {
            index -= 1;
            const candidate = self.nodes[index];
            if (candidate.kind != .directory and candidate.kind != .repo_root) continue;
            if (candidate.depth >= node.depth) continue;
            if (candidate.kind == .directory and !isPathAncestor(candidate.path, node.path)) continue;
            return index;
        }
        return null;
    }

    pub fn isVisible(self: FileTree, node_index: usize, collapsed: *const CollapsedSet) bool {
        if (node_index >= self.nodes.len) return false;
        if (self.nodes[node_index].kind == .repo_root) return true;
        return !hasCollapsedAncestor(self.nodes[node_index].path, collapsed);
    }
};

pub fn build(allocator: std.mem.Allocator, document: diff_parser.DiffDocument) !FileTree {
    return buildWithStatus(allocator, document, null);
}

pub fn buildWithStatus(allocator: std.mem.Allocator, document: diff_parser.DiffDocument, status_document: ?git_status.StatusDocument) !FileTree {
    return buildWithStatusStable(allocator, document, status_document, null);
}

pub fn buildWithStatusStable(
    allocator: std.mem.Allocator,
    document: diff_parser.DiffDocument,
    status_document: ?git_status.StatusDocument,
    stable_order: ?StableOrderOptions,
) !FileTree {
    return buildWithOptions(allocator, document, status_document, .{ .stable_order = stable_order });
}

pub fn buildWithOptions(
    allocator: std.mem.Allocator,
    document: diff_parser.DiffDocument,
    status_document: ?git_status.StatusDocument,
    options: BuildOptions,
) !FileTree {
    var rows: std.ArrayList(RowSource) = .empty;
    defer rows.deinit(allocator);

    var diff_keys: PathKeySet = .empty;
    defer diff_keys.deinit(allocator);

    var status_index: StatusIndex = .empty;
    defer status_index.deinit(allocator);

    if (status_document) |doc| {
        for (doc.entries, 0..) |entry, index| {
            if (entry.isIgnored()) continue;
            const key = entry.canonicalPathKey() orelse continue;
            try status_index.put(allocator, key, index);
        }
    }

    for (document.files, 0..) |file, file_index| {
        const path = displayPath(file);
        const path_key = diff_file.canonicalPathKey(file) orelse path;
        const status_entry = if (status_document) |doc|
            if (status_index.get(path_key)) |index| doc.entries[index] else null
        else
            null;

        if (diff_file.canonicalPathKey(file)) |key| try diff_keys.put(allocator, key, {});

        try rows.append(allocator, .{
            .name = baseName(path),
            .path = path,
            .path_key = path_key,
            .stats = fileStats(file),
            .status = diff_file.status(file),
            .stage_presence = if (status_entry) |entry| stagePresenceFromEntry(entry) else .clean_or_unknown,
            .mode_changed = diff_file.hasModeChange(file),
            .target = .{ .diff_file = file_index },
        });
    }

    if (status_document) |doc| {
        for (doc.entries, 0..) |entry, status_entry_index| {
            if (entry.isIgnored()) continue;
            const key = entry.canonicalPathKey() orelse continue;
            if (diff_keys.contains(key)) continue;

            const path = try allocator.dupe(u8, key);
            try rows.append(allocator, .{
                .name = baseName(path),
                .path = path,
                .path_key = path,
                .stats = statusLineStats(doc, key),
                .status = statusFromEntry(entry),
                .stage_presence = stagePresenceFromEntry(entry),
                .target = .{ .status_entry = status_entry_index },
            });
        }
    }

    std.mem.sort(RowSource, rows.items, {}, rowPathLessThan);
    if (options.stable_order) |stable| try stable.order.remember(stable.allocator, rows.items);

    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    var directory_index: DirectoryIndex = .empty;
    defer directory_index.deinit(allocator);

    for (rows.items) |row| {
        try ensureDirectoryNodes(allocator, &nodes, &directory_index, row.path, row.stats);
        try nodes.append(allocator, .{
            .kind = .file,
            .name = row.name,
            .path = row.path,
            .path_key = row.path_key,
            .depth = pathDepth(row.path),
            .stats = row.stats,
            .status = row.status,
            .stage_presence = row.stage_presence,
            .mode_changed = row.mode_changed,
            .target = row.target,
        });
    }

    try sortNodesForDisplay(allocator, &nodes);
    if (options.root) |root| try prependRootNode(allocator, &nodes, root.name, status_document);

    return .{ .nodes = try nodes.toOwnedSlice(allocator) };
}

fn rowPathLessThan(_: void, lhs: RowSource, rhs: RowSource) bool {
    if (!std.mem.eql(u8, lhs.path_key, rhs.path_key)) return std.mem.lessThan(u8, lhs.path_key, rhs.path_key);
    if (!std.mem.eql(u8, lhs.path, rhs.path)) return std.mem.lessThan(u8, lhs.path, rhs.path);
    return false;
}

const NodeSpan = struct {
    start: usize,
    end: usize,
};

fn sortNodesForDisplay(allocator: std.mem.Allocator, nodes: *std.ArrayList(Node)) !void {
    if (nodes.items.len == 0) return;

    var sorted: std.ArrayList(Node) = .empty;
    errdefer sorted.deinit(allocator);

    _ = try appendSortedNodeRange(allocator, nodes.items, 0, 0, &sorted);

    nodes.deinit(allocator);
    nodes.* = sorted;
}

fn appendSortedNodeRange(
    allocator: std.mem.Allocator,
    source: []const Node,
    start: usize,
    depth: u16,
    out: *std.ArrayList(Node),
) !usize {
    var spans: std.ArrayList(NodeSpan) = .empty;
    defer spans.deinit(allocator);

    var index = start;
    while (index < source.len) {
        if (source[index].depth < depth) break;
        if (source[index].depth > depth) {
            index += 1;
            continue;
        }

        const child_start = index;
        index += 1;
        while (index < source.len and source[index].depth > depth) : (index += 1) {}
        try spans.append(allocator, .{ .start = child_start, .end = index });
    }

    // Sort only sibling roots; each directory's descendants stay attached to
    // that directory and are sorted recursively below it.
    std.mem.sort(NodeSpan, spans.items, source, nodeSpanLessThan);

    for (spans.items) |span| {
        try out.append(allocator, source[span.start]);
        if (span.start + 1 < span.end) {
            _ = try appendSortedNodeRange(allocator, source, span.start + 1, depth + 1, out);
        }
    }

    return index;
}

fn nodeSpanLessThan(source: []const Node, lhs: NodeSpan, rhs: NodeSpan) bool {
    const lhs_node = source[lhs.start];
    const rhs_node = source[rhs.start];
    switch (path_order.displaySiblingOrder(
        lhs_node.kind == .directory,
        lhs_node.name,
        rhs_node.kind == .directory,
        rhs_node.name,
    )) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.lessThan(u8, lhs_node.path, rhs_node.path);
}

fn prependRootNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(Node),
    root_name: []const u8,
    status_document: ?git_status.StatusDocument,
) !void {
    if (nodes.items.len == 0) return;

    var stats: Stats = .{};
    for (nodes.items) |node| {
        if (node.depth != 0) continue;
        stats.add(node.stats);
    }

    for (nodes.items) |*node| {
        node.depth += 1;
    }

    const copied_name = try allocator.dupe(u8, root_name);
    try nodes.insert(allocator, 0, .{
        .kind = .repo_root,
        .name = copied_name,
        .path = "",
        .path_key = "",
        .depth = 0,
        .stats = stats,
        .stage_presence = rootStagePresence(status_document),
        .target = .repo_root,
    });
}

fn rootStagePresence(status_document: ?git_status.StatusDocument) StagePresence {
    const doc = status_document orelse return .clean_or_unknown;
    var saw_staged = false;
    var saw_unstaged = false;
    var saw_untracked = false;
    for (doc.entries) |entry| {
        switch (stagePresenceFromEntry(entry)) {
            .conflict => return .conflict,
            .untracked => saw_untracked = true,
            .unstaged_only => saw_unstaged = true,
            .staged_only => saw_staged = true,
            .mixed => {
                saw_staged = true;
                saw_unstaged = true;
            },
            .clean_or_unknown => {},
        }
    }
    if (saw_untracked and !saw_staged and !saw_unstaged) return .untracked;
    if (saw_staged and (saw_unstaged or saw_untracked)) return .mixed;
    if (saw_staged) return .staged_only;
    if (saw_unstaged or saw_untracked) return .unstaged_only;
    return .clean_or_unknown;
}

pub fn displayPath(file: diff_parser.FileDiff) []const u8 {
    return diff_file.displayPath(file);
}

pub fn fileStats(file: diff_parser.FileDiff) Stats {
    return diff_file.stats(file);
}

fn ensureDirectoryNodes(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(Node),
    directory_index: *DirectoryIndex,
    path: []const u8,
    stats: Stats,
) !void {
    var start: usize = 0;
    var depth: u16 = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        if (slash > start) {
            const dir_path = path[0..slash];
            const dir_index = directory_index.get(dir_path) orelse blk: {
                try nodes.append(allocator, .{
                    .kind = .directory,
                    .name = path[start..slash],
                    .path = dir_path,
                    .depth = depth,
                    .target = .{ .directory = dir_path },
                });
                const new_index = nodes.items.len - 1;
                try directory_index.put(allocator, dir_path, new_index);
                break :blk new_index;
            };
            nodes.items[dir_index].stats.add(stats);
        }
        start = slash + 1;
        depth += 1;
    }
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

fn statusFromEntry(entry: git_status.StatusEntry) ?Status {
    if (entry.isUntracked()) return .added;
    if (entry.index == .renamed or entry.index == .copied or entry.worktree == .renamed or entry.worktree == .copied) return .renamed;
    if (entry.index == .deleted or entry.worktree == .deleted) return .deleted;
    if (entry.index == .added or entry.worktree == .added) return .added;
    if (entry.index == .modified or entry.worktree == .modified or entry.isConflict()) return .modified;
    return null;
}

fn statusLineStats(document: git_status.StatusDocument, key: []const u8) Stats {
    for (document.line_stats) |entry| {
        if (std.mem.eql(u8, entry.path_key, key)) return entry.stats;
    }
    return .{};
}

pub fn stagePresenceFromEntry(entry: git_status.StatusEntry) StagePresence {
    if (entry.isConflict()) return .conflict;
    if (entry.isUntracked()) return .untracked;

    const staged = entry.isStaged();
    const unstaged = entry.isUnstaged();
    if (staged and unstaged) return .mixed;
    if (staged) return .staged_only;
    if (unstaged) return .unstaged_only;
    return .clean_or_unknown;
}

pub fn statusOnlyEntryCount(document: git_status.StatusDocument, diff_document: diff_parser.DiffDocument) usize {
    var count: usize = 0;
    for (document.entries) |entry| {
        if (entry.isIgnored()) continue;
        const key = entry.canonicalPathKey() orelse continue;
        if (diffDocumentHasKey(diff_document, key)) continue;
        count += 1;
    }
    return count;
}

fn diffDocumentHasKey(document: diff_parser.DiffDocument, key: []const u8) bool {
    for (document.files) |file| {
        if (diff_file.canonicalPathKey(file)) |diff_key| {
            if (std.mem.eql(u8, diff_key, key)) return true;
        }
    }
    return false;
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

pub fn expandAncestors(collapsed: *CollapsedSet, path: []const u8) void {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        if (slash > 0) _ = collapsed.remove(path[0..slash]);
        start = slash + 1;
    }
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

pub fn isPathAncestor(ancestor: []const u8, path: []const u8) bool {
    return path.len > ancestor.len and
        std.mem.startsWith(u8, path, ancestor) and
        path[ancestor.len] == '/';
}

/// Return true when `path` is below `directory`.
///
/// Directory nodes are stored without a trailing slash, so this keeps `src/app`
/// from matching the sibling path `src/application.zig`.
pub fn isPathDescendantOfDirectory(path: []const u8, directory: []const u8) bool {
    return isPathAncestor(directory, path);
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
    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[1].kind);
    try std.testing.expectEqualStrings("lib", tree.nodes[1].name);
    try std.testing.expectEqual(Node.Kind.file, tree.nodes[2].kind);
    try std.testing.expectEqualStrings("root.zig", tree.nodes[2].name);
    try std.testing.expectEqual(Node.Kind.file, tree.nodes[3].kind);
    try std.testing.expectEqualStrings("main.zig", tree.nodes[3].name);
    try std.testing.expectEqual(Status.modified, tree.nodes[3].status.?);
    try std.testing.expect(!tree.nodes[3].mode_changed);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodes[3].diffFileIndex());
}

test "buildWithOptions prepends repository root with top-level aggregate stats" {
    const text =
        \\diff --git a/src/lib/root.zig b/src/lib/root.zig
        \\--- a/src/lib/root.zig
        \\+++ b/src/lib/root.zig
        \\@@ -1 +1,3 @@
        \\-old
        \\+new
        \\+added
        \\+more
        \\diff --git a/README.md b/README.md
        \\--- a/README.md
        \\+++ b/README.md
        \\@@ -1 +1,2 @@
        \\-old
        \\+new
        \\+added
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, text);
    const tree = try buildWithOptions(allocator, document, null, .{ .root = .{ .name = "gitframe" } });

    try std.testing.expectEqual(Node.Kind.repo_root, tree.nodes[0].kind);
    try std.testing.expectEqualStrings("gitframe", tree.nodes[0].name);
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].depth);
    try std.testing.expectEqual(@as(usize, 5), tree.nodes[0].stats.added);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes[0].stats.removed);
    try std.testing.expect(tree.nodes[0].target == .repo_root);
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[1].depth);

    var root_file_depth: ?u16 = null;
    for (tree.nodes) |node| {
        if (std.mem.eql(u8, node.path, "src/lib/root.zig")) {
            root_file_depth = node.depth;
            break;
        }
    }
    try std.testing.expectEqual(@as(?u16, 3), root_file_depth);
}

test "buildWithOptions omits repository root without metadata" {
    const text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, text);
    const tree = try buildWithOptions(allocator, document, null, .{});

    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[0].kind);
    try std.testing.expect(tree.nodes[0].target != .repo_root);
}

test "directory descendant matching respects path boundaries" {
    try std.testing.expect(isPathDescendantOfDirectory("src/app/main.zig", "src/app"));
    try std.testing.expect(isPathDescendantOfDirectory("src/lib/root.zig", "src"));
    try std.testing.expect(!isPathDescendantOfDirectory("src/application.zig", "src/app"));
    try std.testing.expect(!isPathDescendantOfDirectory("src/app", "src/app"));
}

test "build sorts sibling directories before files" {
    const text =
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/docs/readme.md b/docs/readme.md
        \\--- a/docs/readme.md
        \\+++ b/docs/readme.md
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

    try std.testing.expectEqual(@as(usize, 6), tree.nodes.len);
    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[0].kind);
    try std.testing.expectEqualStrings("docs", tree.nodes[0].path);
    try std.testing.expectEqualStrings("docs/readme.md", tree.nodes[1].path);
    try std.testing.expectEqual(Node.Kind.directory, tree.nodes[2].kind);
    try std.testing.expectEqualStrings("src", tree.nodes[2].path);
    try std.testing.expectEqualStrings("src/main.zig", tree.nodes[3].path);
    try std.testing.expectEqualStrings("a.zig", tree.nodes[4].path);
    try std.testing.expectEqualStrings("b.zig", tree.nodes[5].path);
}

test "History preview flat path order matches file tree file-node traversal" {
    const text =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/z.zig b/src/z.zig
        \\--- a/src/z.zig
        \\+++ b/src/z.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/lib/root.zig b/src/lib/root.zig
        \\--- a/src/lib/root.zig
        \\+++ b/src/lib/root.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/docs/readme.md b/docs/readme.md
        \\--- a/docs/readme.md
        \\+++ b/docs/readme.md
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

    var flat = [_][]const u8{
        "a.zig",
        "src/z.zig",
        "src/lib/root.zig",
        "src/a.zig",
        "docs/readme.md",
    };
    std.mem.sort([]const u8, &flat, {}, path_order.displayPathLessThan);

    var flat_index: usize = 0;
    for (tree.nodes) |node| {
        if (node.kind != .file) continue;
        try std.testing.expect(flat_index < flat.len);
        try std.testing.expectEqualStrings(node.path_key, flat[flat_index]);
        flat_index += 1;
    }
    try std.testing.expectEqual(flat.len, flat_index);
}

test "buildWithStatus adds untracked status-only rows" {
    const diff_text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, diff_text);
    const status_document = try git_status.parse(allocator, "?? src/new.zig\x00");
    const tree = try buildWithStatus(allocator, document, status_document);

    try std.testing.expectEqual(@as(usize, 3), tree.nodes.len);
    try std.testing.expectEqualStrings("main.zig", tree.nodes[1].name);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodes[1].diffFileIndex());
    try std.testing.expectEqualStrings("new.zig", tree.nodes[2].name);
    try std.testing.expectEqual(Status.added, tree.nodes[2].status.?);
    try std.testing.expect(tree.nodes[2].target == .status_entry);
    try std.testing.expectEqual(@as(usize, 0), tree.nodes[2].target.status_entry);
}

test "buildWithStatus applies status-only line stats to files and directories" {
    const diff_text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1,2 @@
        \\ old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, diff_text);
    const status_entries = [_]git_status.StatusEntry{
        .{ .path = "src/added.zig", .raw = .{ '?', '?' }, .index = .unmodified, .worktree = .untracked },
    };
    const line_stats = [_]git_status.StatusLineStats{
        .{ .path_key = "src/added.zig", .stats = .{ .added = 3, .removed = 0 } },
    };
    const status_document: git_status.StatusDocument = .{ .entries = &status_entries, .line_stats = &line_stats };

    const tree = try buildWithStatus(allocator, document, status_document);

    try std.testing.expectEqual(@as(usize, 3), tree.nodes.len);
    try std.testing.expectEqualStrings("src", tree.nodes[0].path);
    try std.testing.expectEqual(@as(usize, 4), tree.nodes[0].stats.added);
    try std.testing.expectEqualStrings("src/added.zig", tree.nodes[1].path);
    try std.testing.expectEqual(@as(usize, 3), tree.nodes[1].stats.added);
    try std.testing.expectEqualStrings("src/main.zig", tree.nodes[2].path);
    try std.testing.expectEqual(@as(usize, 1), tree.nodes[2].stats.added);
}

test "buildWithStatus skips rows already present in diff" {
    const diff_text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, diff_text);
    const status_document = try git_status.parse(allocator, " M src/main.zig\x00!! ignored.tmp\x00");
    const tree = try buildWithStatus(allocator, document, status_document);

    try std.testing.expectEqual(@as(usize, 2), tree.nodes.len);
    try std.testing.expectEqualStrings("main.zig", tree.nodes[1].name);
    try std.testing.expectEqual(@as(?usize, 0), tree.nodes[1].diffFileIndex());
}

test "buildWithStatusStable applies final display sort after reloads" {
    const first_text =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/c.zig b/c.zig
        \\--- a/c.zig
        \\+++ b/c.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    const second_text =
        \\diff --git a/c.zig b/c.zig
        \\--- a/c.zig
        \\+++ b/c.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var order: StableOrder = .{};
    defer order.deinit(std.testing.allocator);

    const first_doc = try diff_parser.parse(arena_allocator, first_text);
    const first_tree = try buildWithStatusStable(arena_allocator, first_doc, null, .{
        .allocator = std.testing.allocator,
        .order = &order,
    });
    try std.testing.expectEqualStrings("a.zig", first_tree.nodes[0].path);
    try std.testing.expectEqualStrings("c.zig", first_tree.nodes[1].path);

    const second_doc = try diff_parser.parse(arena_allocator, second_text);
    const second_tree = try buildWithStatusStable(arena_allocator, second_doc, null, .{
        .allocator = std.testing.allocator,
        .order = &order,
    });

    try std.testing.expectEqualStrings("a.zig", second_tree.nodes[0].path);
    try std.testing.expectEqualStrings("b.zig", second_tree.nodes[1].path);
    try std.testing.expectEqualStrings("c.zig", second_tree.nodes[2].path);
}

test "buildWithStatusStable keeps nested additions attached after reloads" {
    const first_text =
        \\diff --git a/docs/readme.md b/docs/readme.md
        \\--- a/docs/readme.md
        \\+++ b/docs/readme.md
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    const second_text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/docs/z.md b/docs/z.md
        \\--- a/docs/z.md
        \\+++ b/docs/z.md
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/docs/readme.md b/docs/readme.md
        \\--- a/docs/readme.md
        \\+++ b/docs/readme.md
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var order: StableOrder = .{};
    defer order.deinit(std.testing.allocator);

    const first_doc = try diff_parser.parse(arena_allocator, first_text);
    _ = try buildWithStatusStable(arena_allocator, first_doc, null, .{
        .allocator = std.testing.allocator,
        .order = &order,
    });

    const second_doc = try diff_parser.parse(arena_allocator, second_text);
    const second_tree = try buildWithStatusStable(arena_allocator, second_doc, null, .{
        .allocator = std.testing.allocator,
        .order = &order,
    });

    try std.testing.expectEqual(@as(usize, 6), second_tree.nodes.len);
    try std.testing.expectEqualStrings("docs", second_tree.nodes[0].path);
    try std.testing.expectEqualStrings("docs/readme.md", second_tree.nodes[1].path);
    try std.testing.expectEqualStrings("docs/z.md", second_tree.nodes[2].path);
    try std.testing.expectEqualStrings("src", second_tree.nodes[3].path);
    try std.testing.expectEqualStrings("src/a.zig", second_tree.nodes[4].path);
    try std.testing.expectEqualStrings("src/main.zig", second_tree.nodes[5].path);
}

test "buildWithStatus records staged-only and mixed presence separately from status" {
    const diff_text =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, diff_text);
    const status_document = try git_status.parse(allocator, "MM src/main.zig\x00M  src/staged.zig\x00");
    const tree = try buildWithStatus(allocator, document, status_document);

    try std.testing.expectEqual(StagePresence.mixed, tree.nodes[1].stage_presence);
    try std.testing.expectEqual(Status.modified, tree.nodes[1].status.?);
    try std.testing.expectEqual(StagePresence.staged_only, tree.nodes[2].stage_presence);
    try std.testing.expectEqual(Status.modified, tree.nodes[2].status.?);
}

test "build marks file nodes with mode metadata" {
    const text =
        \\diff --git a/script.sh b/script.sh
        \\old mode 100644
        \\new mode 100755
        \\--- a/script.sh
        \\+++ b/script.sh
        \\@@ -1 +1 @@
        \\-echo old
        \\+echo new
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try diff_parser.parse(allocator, text);
    const tree = try build(allocator, document);

    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try std.testing.expectEqual(Node.Kind.file, tree.nodes[0].kind);
    try std.testing.expect(tree.nodes[0].mode_changed);
}

test "selectedNodeIndex maps file index to tree row" {
    const nodes = [_]Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 1, .target = .{ .diff_file = 0 } },
    };
    const tree = FileTree{ .nodes = &nodes };

    try std.testing.expectEqual(@as(?usize, 1), tree.selectedNodeIndex(0));
    try std.testing.expectEqual(@as(?usize, null), tree.selectedNodeIndex(1));
}

test "collapsed directory hides descendants but remains visible" {
    const nodes = [_]Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 1, .target = .{ .diff_file = 0 } },
        .{ .kind = .directory, .name = "test", .path = "test", .depth = 0 },
        .{ .kind = .file, .name = "main.zig", .path = "test/main.zig", .depth = 1, .target = .{ .diff_file = 1 } },
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

test "parentDirectoryNodeIndex finds nearest directory ancestor" {
    const nodes = [_]Node{
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 0 },
        .{ .kind = .directory, .name = "lib", .path = "src/lib", .depth = 1 },
        .{ .kind = .file, .name = "root.zig", .path = "src/lib/root.zig", .depth = 2, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "README.md", .path = "README.md", .depth = 0, .target = .{ .diff_file = 1 } },
    };
    const tree = FileTree{ .nodes = &nodes };

    try std.testing.expectEqual(@as(?usize, 1), tree.parentDirectoryNodeIndex(2));
    try std.testing.expectEqual(@as(?usize, 0), tree.parentDirectoryNodeIndex(1));
    try std.testing.expectEqual(@as(?usize, null), tree.parentDirectoryNodeIndex(0));
    try std.testing.expectEqual(@as(?usize, null), tree.parentDirectoryNodeIndex(3));
    try std.testing.expectEqual(@as(?usize, null), tree.parentDirectoryNodeIndex(99));
}

test "parentDirectoryNodeIndex treats repository root as the top-level parent" {
    const nodes = [_]Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .directory, .name = "src", .path = "src", .depth = 1 },
        .{ .kind = .file, .name = "main.zig", .path = "src/main.zig", .depth = 2, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "README.md", .path = "README.md", .depth = 1, .target = .{ .diff_file = 1 } },
    };
    const tree = FileTree{ .nodes = &nodes };

    try std.testing.expectEqual(@as(?usize, 1), tree.parentDirectoryNodeIndex(2));
    try std.testing.expectEqual(@as(?usize, 0), tree.parentDirectoryNodeIndex(1));
    try std.testing.expectEqual(@as(?usize, 0), tree.parentDirectoryNodeIndex(3));
    try std.testing.expectEqual(@as(?usize, null), tree.parentDirectoryNodeIndex(0));
}

test "expandAncestors reveals nested file path" {
    var collapsed: CollapsedSet = .empty;
    defer collapsed.deinit(std.testing.allocator);

    try collapse(std.testing.allocator, &collapsed, "src");
    try collapse(std.testing.allocator, &collapsed, "src/lib");

    expandAncestors(&collapsed, "src/lib/root.zig");

    try std.testing.expect(!isCollapsed(&collapsed, "src"));
    try std.testing.expect(!isCollapsed(&collapsed, "src/lib"));
}
