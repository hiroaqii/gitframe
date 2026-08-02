//! Review file-search candidate ownership and semantic identity.
//!
//! A candidate is more than a tree index: it borrows an exact path from one
//! accepted sidebar owner and is valid only for that owner's repository,
//! source session, and sidebar revision. Keeping this contract in Review page
//! state lets rendering and submit consume the same typed candidate while
//! reload code can clear every borrow before replacing its arena.

const std = @import("std");
const ui = @import("chasen_ui");
const prompt = @import("../prompt.zig");
const context = @import("../../context.zig");
const file_tree = @import("../../file_tree.zig");
const loaded_diff = @import("../../loaded_diff.zig");

pub const max_candidates: usize = 512;

/// Complete semantic generation of the sidebar rows searched by a projection.
///
/// `accepted_sidebar_revision` is deliberately non-zero. Zero means that no
/// accepted sidebar generation has ever been established and therefore cannot
/// authorize a borrowed candidate.
pub const Basis = struct {
    repo_epoch: u64,
    source_session_revision: u64,
    accepted_sidebar_revision: u64,

    pub fn valid(self: Basis) bool {
        return self.accepted_sidebar_revision != 0;
    }

    pub fn eql(a: Basis, b: Basis) bool {
        return a.repo_epoch == b.repo_epoch and
            a.source_session_revision == b.source_session_revision and
            a.accepted_sidebar_revision == b.accepted_sidebar_revision;
    }
};

/// File destinations intentionally exclude directory and synthetic root rows.
/// The target kind is part of identity: a status-only row replacing a diff row
/// at the same path is a different candidate.
pub const TargetKind = enum {
    diff_file,
    status_only,

    pub fn fromSidebarTarget(target: context.SidebarTarget) ?TargetKind {
        return switch (target) {
            .diff_file => .diff_file,
            .status_entry => .status_only,
            .repo_root, .directory => null,
        };
    }
};

/// One displayed result. `path_key` borrows the accepted load arena named by
/// `basis`; the candidate array owns only the slice descriptors.
pub const Candidate = struct {
    basis: Basis,
    target_kind: TargetKind,
    node_index: usize,
    path_key: context.PathKey,

    pub fn matchesNode(self: Candidate, basis: Basis, node_index: usize, node: file_tree.Node) bool {
        if (!self.basis.eql(basis) or self.node_index != node_index) return false;
        const target_kind = TargetKind.fromSidebarTarget(node.target) orelse return false;
        return self.target_kind == target_kind and std.mem.eql(u8, self.path_key, node.path_key);
    }
};

/// Fully prepared result set used for atomic publication into `State`.
///
/// The filter owns its query/index/label arrays. Candidate and filter path
/// slices still borrow the accepted sidebar owner, so callers must deinit this
/// projection before freeing that owner when publication does not occur.
pub const Projection = struct {
    basis: Basis,
    candidates: []Candidate,
    filter: ui.ListFilter,
    truncated: bool = false,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        // Filter labels borrow candidate paths. Release the containers which
        // expose those borrows before releasing the candidate descriptor array.
        self.filter.deinit(allocator);
        allocator.free(self.candidates);
        self.* = undefined;
    }
};

pub const BuildOptions = struct {
    basis: Basis,
    hide_reviewed_files: bool = false,
    changed_file_filter: loaded_diff.ChangedFileFilter = .all,
};

/// Prepare one bounded projection without mutating the live prompt state.
///
/// The scan intentionally uses every accepted tree node rather than only the
/// materialized visible rows: a matching file remains discoverable below a
/// collapsed root/directory, while Review's hide-reviewed and changed-file
/// lenses still define candidate eligibility. Only matching rows consume the
/// fixed result budget, so an early non-match cannot hide a later match.
pub fn buildProjection(
    allocator: std.mem.Allocator,
    loaded: *const loaded_diff.LoadedDiff,
    query: []const u8,
    options: BuildOptions,
) !Projection {
    if (!options.basis.valid()) return error.InvalidBasis;

    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);

    var truncated = false;
    for (loaded.tree.nodes, 0..) |node, node_index| {
        if (node.kind != .file or node.path_key.len == 0) continue;
        const target_kind = TargetKind.fromSidebarTarget(node.target) orelse continue;
        if (!loaded.shouldIncludeFileNode(
            node_index,
            options.hide_reviewed_files,
            options.changed_file_filter,
        )) continue;
        if (!ui.list_filter.matchesLabel(node.path, query)) continue;
        if (candidates.items.len == max_candidates) {
            truncated = true;
            break;
        }

        try candidates.append(allocator, .{
            .basis = options.basis,
            .target_kind = target_kind,
            .node_index = node_index,
            .path_key = node.path_key,
        });
        try labels.append(allocator, node.path);
    }

    const owned_candidates = try candidates.toOwnedSlice(allocator);
    errdefer allocator.free(owned_candidates);
    var filter: ui.ListFilter = .{};
    errdefer filter.deinit(allocator);
    // The pre-scan enforces the result budget. Applying the same matcher again
    // gives ListFilter ownership of its query/index/label containers and keeps
    // its source indexes aligned exactly with `owned_candidates`.
    try filter.apply(allocator, labels.items, query);
    std.debug.assert(filter.labels.len == owned_candidates.len);

    return .{
        .basis = options.basis,
        .candidates = owned_candidates,
        .filter = filter,
        .truncated = truncated,
    };
}

/// Review-owned prompt and candidate projection.
///
/// Prompt input survives an unavailable rebuild. Candidate data does not: an
/// unavailable state always owns no arrays and therefore cannot accidentally
/// submit or render a stale load-arena borrow.
pub const State = struct {
    mode: bool = false,
    input: prompt.TextInput = .{},
    filter: ui.ListFilter = .{},
    candidates: []Candidate = &.{},
    basis: ?Basis = null,
    projection_available: bool = false,
    truncated: bool = false,
    no_match: bool = false,

    pub fn resetNoMatch(self: *State) void {
        self.no_match = false;
    }

    /// Release all projection-owned containers while the accepted sidebar
    /// owner which supplies borrowed paths is still alive.
    pub fn clearFilter(self: *State, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        allocator.free(self.candidates);
        self.filter = .{};
        self.candidates = &.{};
        self.basis = null;
        self.projection_available = false;
        self.truncated = false;
    }

    pub fn publish(self: *State, allocator: std.mem.Allocator, projection: *Projection) void {
        std.debug.assert(projection.basis.valid());
        for (projection.candidates) |candidate| std.debug.assert(candidate.basis.eql(projection.basis));

        self.clearFilter(allocator);
        self.filter = projection.filter;
        self.candidates = projection.candidates;
        self.basis = projection.basis;
        self.projection_available = true;
        self.truncated = projection.truncated;
        self.no_match = self.filter.labels.len == 0;
        projection.* = undefined;
    }

    /// Publish the failure terminal without discarding prompt mode or input.
    pub fn markProjectionUnavailable(self: *State, allocator: std.mem.Allocator) void {
        self.clearFilter(allocator);
        self.no_match = false;
    }

    pub fn move(self: *State, delta: isize) void {
        if (!self.projection_available or self.filter.labels.len == 0) return;
        self.filter.update(if (delta < 0) .move_prev else .move_next);
    }

    /// Resolve one visible filter row through the owned candidate map.
    /// Rendering and activation both use this boundary so neither can treat a
    /// borrowed label as an independently authoritative destination.
    pub fn candidateAt(self: *const State, visible_index: usize) ?Candidate {
        if (!self.projection_available) return null;
        const candidate_index = self.filter.sourceIndex(visible_index) orelse return null;
        if (candidate_index >= self.candidates.len) return null;
        const candidate = self.candidates[candidate_index];
        const basis = self.basis orelse return null;
        return if (candidate.basis.eql(basis)) candidate else null;
    }

    pub fn focusedCandidate(self: *const State) ?Candidate {
        return self.candidateAt(self.filter.list.focusedIndex());
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearFilter(allocator);
        self.* = .{};
    }
};

/// Advance a generation while reserving zero as the invalid sentinel.
pub fn nextAcceptedSidebarRevision(current: u64) u64 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "review file search basis requires a nonzero accepted sidebar revision" {
    const invalid: Basis = .{ .repo_epoch = 4, .source_session_revision = 9, .accepted_sidebar_revision = 0 };
    const valid: Basis = .{ .repo_epoch = 4, .source_session_revision = 9, .accepted_sidebar_revision = 1 };
    try std.testing.expect(!invalid.valid());
    try std.testing.expect(valid.valid());
    try std.testing.expect(valid.eql(valid));
    try std.testing.expect(!valid.eql(.{ .repo_epoch = 5, .source_session_revision = 9, .accepted_sidebar_revision = 1 }));
    try std.testing.expect(!valid.eql(.{ .repo_epoch = 4, .source_session_revision = 10, .accepted_sidebar_revision = 1 }));
    try std.testing.expect(!valid.eql(.{ .repo_epoch = 4, .source_session_revision = 9, .accepted_sidebar_revision = 2 }));
    try std.testing.expectEqual(@as(u64, 1), nextAcceptedSidebarRevision(std.math.maxInt(u64)));
}

test "review file search publishes and focuses one exact typed candidate" {
    const allocator = std.testing.allocator;
    const basis: Basis = .{ .repo_epoch = 2, .source_session_revision = 3, .accepted_sidebar_revision = 4 };
    const candidates = try allocator.dupe(Candidate, &.{
        .{ .basis = basis, .target_kind = .diff_file, .node_index = 1, .path_key = "src/a.zig" },
        .{ .basis = basis, .target_kind = .status_only, .node_index = 2, .path_key = "src/b.zig" },
    });
    var filter: ui.ListFilter = .{};
    errdefer filter.deinit(allocator);
    const labels = [_][]const u8{ candidates[0].path_key, candidates[1].path_key };
    const indexes = [_]usize{ 0, 1 };
    try filter.applyWithSourceIndexes(allocator, &labels, &indexes, "src/");

    var projection: Projection = .{ .basis = basis, .candidates = candidates, .filter = filter };
    filter = .{};
    var state: State = .{ .mode = true };
    defer state.deinit(allocator);
    state.publish(allocator, &projection);

    try std.testing.expectEqualStrings("src/a.zig", state.candidateAt(0).?.path_key);
    try std.testing.expectEqualStrings("src/b.zig", state.candidateAt(1).?.path_key);
    try std.testing.expect(state.candidateAt(2) == null);
    try std.testing.expectEqual(TargetKind.diff_file, state.focusedCandidate().?.target_kind);
    state.move(1);
    const focused = state.focusedCandidate().?;
    try std.testing.expectEqual(TargetKind.status_only, focused.target_kind);
    try std.testing.expectEqualStrings("src/b.zig", focused.path_key);

    const matching_node: file_tree.Node = .{
        .kind = .file,
        .name = "b.zig",
        .path = "src/b.zig",
        .path_key = "src/b.zig",
        .depth = 1,
        .target = .{ .status_entry = 7 },
    };
    try std.testing.expect(focused.matchesNode(basis, 2, matching_node));
    try std.testing.expect(!focused.matchesNode(basis, 1, matching_node));
    try std.testing.expect(!focused.matchesNode(
        .{ .repo_epoch = 2, .source_session_revision = 3, .accepted_sidebar_revision = 5 },
        2,
        matching_node,
    ));
    var wrong_target = matching_node;
    wrong_target.target = .{ .diff_file = 7 };
    try std.testing.expect(!focused.matchesNode(basis, 2, wrong_target));
    var wrong_path = matching_node;
    wrong_path.path_key = "src/c.zig";
    try std.testing.expect(!focused.matchesNode(basis, 2, wrong_path));
}

test "review file search unavailable terminal keeps prompt and owns no stale candidates" {
    const allocator = std.testing.allocator;
    const basis: Basis = .{ .repo_epoch = 1, .source_session_revision = 1, .accepted_sidebar_revision = 1 };
    const candidates = try allocator.dupe(Candidate, &.{.{
        .basis = basis,
        .target_kind = .diff_file,
        .node_index = 0,
        .path_key = "main.zig",
    }});
    var filter: ui.ListFilter = .{};
    errdefer filter.deinit(allocator);
    const labels = [_][]const u8{candidates[0].path_key};
    try filter.apply(allocator, &labels, "main");
    var projection: Projection = .{ .basis = basis, .candidates = candidates, .filter = filter };
    filter = .{};

    var state: State = .{ .mode = true };
    defer state.deinit(allocator);
    try state.input.insertSlice("main");
    state.publish(allocator, &projection);
    state.markProjectionUnavailable(allocator);

    try std.testing.expect(state.mode);
    try std.testing.expectEqualStrings("main", state.input.slice());
    try std.testing.expect(!state.projection_available);
    try std.testing.expect(!state.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.candidates.len);
    try std.testing.expect(state.focusedCandidate() == null);
}

test "review file search builder applies lenses but searches collapsed descendants" {
    const allocator = std.testing.allocator;
    const nodes = [_]file_tree.Node{
        .{ .kind = .repo_root, .name = "repo", .path = "", .depth = 0, .target = .repo_root },
        .{ .kind = .directory, .name = "src", .path = "src", .path_key = "src", .depth = 0, .target = .{ .directory = "src" } },
        .{ .kind = .file, .name = "a.zig", .path = "src/a.zig", .path_key = "src/a.zig", .depth = 1, .status = .modified, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "b.zig", .path = "src/b.zig", .path_key = "src/b.zig", .depth = 1, .status = .added, .target = .{ .status_entry = 4 } },
        .{ .kind = .file, .name = "reviewed.zig", .path = "src/reviewed.zig", .path_key = "src/reviewed.zig", .depth = 1, .status = .modified, .target = .{ .diff_file = 1 } },
    };
    const reviewed = [_]bool{ false, true };
    var loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .reviewed_files = @constCast(&reviewed),
        .bytes = 0,
        .lines = 0,
    };
    try loaded.collapsed_dirs.put(allocator, "src", {});
    defer loaded.collapsed_dirs.deinit(allocator);
    const basis: Basis = .{ .repo_epoch = 7, .source_session_revision = 8, .accepted_sidebar_revision = 9 };

    var all = try buildProjection(allocator, &loaded, "SRC/", .{
        .basis = basis,
        .hide_reviewed_files = true,
    });
    defer all.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), all.candidates.len);
    try std.testing.expectEqual(TargetKind.diff_file, all.candidates[0].target_kind);
    try std.testing.expectEqual(TargetKind.status_only, all.candidates[1].target_kind);
    try std.testing.expectEqualStrings("src/a.zig", all.filter.labels[0]);
    try std.testing.expectEqualStrings("src/b.zig", all.filter.labels[1]);
    try std.testing.expect(!all.truncated);

    var modified = try buildProjection(allocator, &loaded, "src/", .{
        .basis = basis,
        .changed_file_filter = .modified,
    });
    defer modified.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), modified.candidates.len);
    try std.testing.expectEqualStrings("src/a.zig", modified.filter.labels[0]);
    try std.testing.expectEqualStrings("src/reviewed.zig", modified.filter.labels[1]);
}

test "review file search builder bounds matching candidates and reports truncation" {
    const allocator = std.testing.allocator;
    const nodes = try allocator.alloc(file_tree.Node, max_candidates + 1);
    defer allocator.free(nodes);
    for (nodes, 0..) |*node, index| node.* = .{
        .kind = .file,
        .name = "match.zig",
        .path = "match.zig",
        .path_key = "match.zig",
        .depth = 0,
        .target = .{ .status_entry = index },
    };
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = nodes },
        .bytes = 0,
        .lines = 0,
    };
    const basis: Basis = .{ .repo_epoch = 1, .source_session_revision = 1, .accepted_sidebar_revision = 1 };

    var projection = try buildProjection(allocator, &loaded, "match", .{ .basis = basis });
    defer projection.deinit(allocator);
    try std.testing.expectEqual(max_candidates, projection.candidates.len);
    try std.testing.expect(projection.truncated);
}

test "review file search builder releases every partial allocation" {
    const nodes = [_]file_tree.Node{.{
        .kind = .file,
        .name = "main.zig",
        .path = "src/main.zig",
        .path_key = "src/main.zig",
        .depth = 1,
        .target = .{ .diff_file = 0 },
    }};
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };
    const basis: Basis = .{ .repo_epoch = 1, .source_session_revision = 2, .accepted_sidebar_revision = 3 };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn build(
            allocator: std.mem.Allocator,
            source: *const loaded_diff.LoadedDiff,
            expected_basis: Basis,
        ) !void {
            var projection = try buildProjection(allocator, source, "main", .{ .basis = expected_basis });
            defer projection.deinit(allocator);
        }
    }.build, .{ &loaded, basis });
}
