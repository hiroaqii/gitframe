const std = @import("std");
const diff_source = @import("../diff/source.zig");
const file_tree = @import("../file_tree.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_status = @import("../git/status.zig");

/// App-local Git operation target classification.
///
/// This module describes what the current UI selection resolved to before a
/// concrete async task is started. Concrete git command execution remains in
/// app/actions.zig.
pub const TargetKind = enum {
    file,
    directory,
};

/// Trim leading/trailing whitespace from command output before showing it in UI.
pub fn trimGitOutput(message: []const u8) []const u8 {
    return std.mem.trim(u8, message, " \t\r\n");
}

pub const PathTarget = struct {
    path: []const u8,
    kind: TargetKind,
};

pub const ToggleStageOperation = enum {
    stage,
    unstage,
};

pub const StageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    kind: TargetKind,
};

pub const StageTargetResult = union(enum) {
    ready: StageTarget,
    already_staged: []const u8,
    stale_status,
    conflict_unsupported: []const u8,
    no_stageable_content: []const u8,
    unavailable_source,
    no_repo,
    no_path,
};

pub const ToggleStageTargetResult = union(enum) {
    operation: ToggleStageOperation,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    conflict_unsupported: PathTarget,
    no_content: PathTarget,
};

pub const HunkMarkSource = enum {
    session,
    projection,
};

pub const HunkStageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    hunk_index: usize,
    /// Owned patch text returned by target resolution and transferred to the
    /// async task when the request is started.
    patch: []u8,
    mark_source: HunkMarkSource = .session,
    reload_after_success: bool = false,
};

pub const HunkStageTargetResult = union(enum) {
    ready: HunkStageTarget,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
    stale_status,
    conflict_unsupported,
    binary_unsupported,
    unsupported_file_state,
    already_staged_hunk,
    patch_failed,
};

pub const HunkUnstageTarget = HunkStageTarget;

pub const HunkUnstageTargetResult = union(enum) {
    ready: HunkUnstageTarget,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
    not_staged_hunk,
    binary_unsupported,
    unsupported_file_state,
    patch_failed,
};

pub const ToggleHunkTargetResult = union(enum) {
    operation: ToggleStageOperation,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
};

pub const UnstageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    kind: TargetKind,
};

pub const UnstageTargetResult = union(enum) {
    ready: UnstageTarget,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    conflict_unsupported: PathTarget,
    no_staged_content: PathTarget,
};

pub const DiscardTarget = struct {
    repo_root: []const u8,
    path: []const u8,
};

pub const DiscardTargetResult = union(enum) {
    ready: DiscardTarget,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    directory_unsupported,
    conflict_unsupported,
    untracked_unsupported,
    no_unstaged_content,
};

pub const PushTarget = struct {
    repo_root: []const u8,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    oid: []const u8,
    ahead: u32,
    behind: u32,
};

pub const PushTargetResult = union(enum) {
    ready: PushTarget,
    unavailable_source,
    no_repo,
    loading_branch_status,
    detached_head,
    branch_unavailable,
    no_upstream,
    upstream_not_remote_branch,
    branch_status_unavailable,
    pull_first,
    nothing_to_push,
};

pub const StatusSnapshot = struct {
    /// Repo root used by the most recent status load.
    repo_root: ?[]const u8,
    loading: bool,
    entries: []const git_status.StatusEntry,

    pub fn entryForPathKey(self: StatusSnapshot, path_key: []const u8) ?git_status.StatusEntry {
        for (self.entries) |entry| {
            const entry_key = entry.canonicalPathKey() orelse continue;
            if (std.mem.eql(u8, entry_key, path_key)) return entry;
        }
        return null;
    }

    pub fn freshEntryForPathKey(self: StatusSnapshot, active_repo_root: []const u8, path_key: []const u8) ?git_status.StatusEntry {
        if (self.loading) return null;
        const snapshot_root = self.repo_root orelse return null;
        if (!std.mem.eql(u8, snapshot_root, active_repo_root)) return null;
        return self.entryForPathKey(path_key);
    }

    fn isFreshFor(self: StatusSnapshot, active_repo_root: []const u8) bool {
        if (self.loading) return false;
        const snapshot_root = self.repo_root orelse return false;
        return std.mem.eql(u8, snapshot_root, active_repo_root);
    }
};

pub const TargetContext = struct {
    source: diff_source.SourceMode,
    /// Currently selected active repo root from App state.
    repo_root: ?[]const u8,
    action_target: ?PathTarget,
    status: StatusSnapshot,
};

pub const BranchStatusSnapshot = struct {
    repo_root: ?[]const u8,
    loading: bool,
    status: git_branch_status.BranchStatus,

    fn freshFor(self: BranchStatusSnapshot, active_repo_root: []const u8) bool {
        if (self.loading) return false;
        const snapshot_root = self.repo_root orelse return false;
        return std.mem.eql(u8, snapshot_root, active_repo_root);
    }
};

pub const RemoteActionContext = struct {
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    branch_status: BranchStatusSnapshot,
};

pub fn pushTarget(ctx: RemoteActionContext) PushTargetResult {
    if (!diff_source.sourceAllowsStageProjection(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    if (!ctx.branch_status.freshFor(repo_root)) return .loading_branch_status;

    const status = ctx.branch_status.status;
    const branch = switch (status.head) {
        .branch => |name| name,
        .detached => return .detached_head,
        .unknown => return .branch_unavailable,
    };
    const upstream = status.upstream orelse return .no_upstream;
    if (upstream.remote_branch.len == 0) return .upstream_not_remote_branch;
    const oid = status.oid orelse return .branch_status_unavailable;
    const ahead_behind = status.ahead_behind orelse return .branch_status_unavailable;
    if (ahead_behind.behind > 0) return .pull_first;
    if (ahead_behind.ahead == 0) return .nothing_to_push;

    return .{ .ready = .{
        .repo_root = repo_root,
        .branch = branch,
        .remote = upstream.remote,
        .remote_branch = upstream.remote_branch,
        .oid = oid,
        .ahead = ahead_behind.ahead,
        .behind = ahead_behind.behind,
    } };
}

pub fn stageTarget(ctx: TargetContext) StageTargetResult {
    if (!diff_source.sourceAllowsStageAction(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    return switch (action_target.kind) {
        .file => fileStageTarget(repo_root, action_target, ctx.status),
        .directory => directoryStageTarget(repo_root, action_target.path, ctx.status),
    };
}

fn fileStageTarget(repo_root: []const u8, action_target: PathTarget, status: StatusSnapshot) StageTargetResult {
    // Staging is intentionally optimistic: stale status only disables the
    // already-staged suppression check, while git add itself remains safe.
    if (status.freshEntryForPathKey(repo_root, action_target.path)) |entry| {
        if (!entry.isConflict() and entry.isStaged() and !entry.isUnstaged()) return .{ .already_staged = action_target.path };
    }
    return .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file } };
}

fn directoryStageTarget(repo_root: []const u8, directory: []const u8, status: StatusSnapshot) StageTargetResult {
    if (!status.isFreshFor(repo_root)) return .stale_status;

    var has_stageable = false;
    for (status.entries) |entry| {
        const key = entry.canonicalPathKey() orelse continue;
        if (!file_tree.isPathDescendantOfDirectory(key, directory)) continue;

        // Git operates on the whole directory path. Reject conflicts here so
        // first-slice directory actions cannot resolve them implicitly.
        if (entry.isConflict()) return .{ .conflict_unsupported = directory };

        switch (file_tree.stagePresenceFromEntry(entry)) {
            .untracked, .unstaged_only, .mixed => has_stageable = true,
            .staged_only, .clean_or_unknown, .conflict => {},
        }
    }

    if (!has_stageable) return .{ .no_stageable_content = directory };
    return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory } };
}

pub fn toggleStageTarget(ctx: TargetContext) ToggleStageTargetResult {
    const can_stage = diff_source.sourceAllowsStageAction(ctx.source);
    const can_unstage = diff_source.sourceAllowsUnstageAction(ctx.source);
    if (!can_stage and !can_unstage) return .unavailable_source;

    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (!ctx.status.isFreshFor(repo_root)) return .stale_status;

    return switch (action_target.kind) {
        .file => fileStageToggleOperation(action_target, can_stage, can_unstage, ctx.status),
        .directory => directoryStageToggleOperation(action_target, can_stage, can_unstage, ctx.status),
    };
}

fn fileStageToggleOperation(action_target: PathTarget, can_stage: bool, can_unstage: bool, status: StatusSnapshot) ToggleStageTargetResult {
    const entry = status.entryForPathKey(action_target.path) orelse return .{ .no_content = action_target };
    if (entry.isConflict()) return .{ .conflict_unsupported = action_target };
    if (entry.isUnstaged()) return if (can_stage) .{ .operation = .stage } else .unavailable_source;
    if (entry.isStaged()) return if (can_unstage) .{ .operation = .unstage } else .unavailable_source;
    return .{ .no_content = action_target };
}

fn directoryStageToggleOperation(action_target: PathTarget, can_stage: bool, can_unstage: bool, status: StatusSnapshot) ToggleStageTargetResult {
    var has_unstaged = false;
    var has_staged = false;
    for (status.entries) |entry| {
        const key = entry.canonicalPathKey() orelse continue;
        if (!file_tree.isPathDescendantOfDirectory(key, action_target.path)) continue;

        if (entry.isConflict()) return .{ .conflict_unsupported = action_target };
        if (entry.isUnstaged()) has_unstaged = true;
        if (entry.isStaged()) has_staged = true;
    }

    if (has_unstaged) return if (can_stage) .{ .operation = .stage } else .unavailable_source;
    if (has_staged) return if (can_unstage) .{ .operation = .unstage } else .unavailable_source;
    return .{ .no_content = action_target };
}

pub fn unstageTarget(ctx: TargetContext) UnstageTargetResult {
    if (!diff_source.sourceAllowsUnstageAction(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (!ctx.status.isFreshFor(repo_root)) return .stale_status;
    return switch (action_target.kind) {
        .file => fileUnstageTarget(repo_root, action_target, ctx.status),
        .directory => directoryUnstageTarget(repo_root, action_target.path, ctx.status),
    };
}

fn fileUnstageTarget(repo_root: []const u8, action_target: PathTarget, status: StatusSnapshot) UnstageTargetResult {
    const entry = status.entryForPathKey(action_target.path) orelse return .{ .no_staged_content = action_target };
    if (entry.isConflict()) return .{ .conflict_unsupported = action_target };
    if (!entry.isStaged()) return .{ .no_staged_content = action_target };
    return .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file } };
}

fn directoryUnstageTarget(repo_root: []const u8, directory: []const u8, status: StatusSnapshot) UnstageTargetResult {
    if (!status.isFreshFor(repo_root)) return .stale_status;

    var has_staged = false;
    for (status.entries) |entry| {
        const key = entry.canonicalPathKey() orelse continue;
        if (!file_tree.isPathDescendantOfDirectory(key, directory)) continue;

        if (entry.isConflict()) return .{ .conflict_unsupported = .{ .path = directory, .kind = .directory } };

        switch (file_tree.stagePresenceFromEntry(entry)) {
            .staged_only, .mixed => has_staged = true,
            .untracked, .unstaged_only, .clean_or_unknown, .conflict => {},
        }
    }

    if (!has_staged) return .{ .no_staged_content = .{ .path = directory, .kind = .directory } };
    return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory } };
}

pub fn discardTarget(ctx: TargetContext) DiscardTargetResult {
    if (!diff_source.sourceAllowsStageAction(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (action_target.kind == .directory) return .directory_unsupported;
    const entry = ctx.status.freshEntryForPathKey(repo_root, action_target.path) orelse return .stale_status;
    if (entry.isConflict()) return .conflict_unsupported;
    return switch (file_tree.stagePresenceFromEntry(entry)) {
        .unstaged_only, .mixed => .{ .ready = .{ .repo_root = repo_root, .path = action_target.path } },
        .untracked => .untracked_unsupported,
        .staged_only, .clean_or_unknown, .conflict => .no_unstaged_content,
    };
}

test "stageTarget file allows stale status while suppressing fresh staged-only files" {
    const target: PathTarget = .{ .path = "src/main.zig", .kind = .file };

    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = target,
        .status = .{ .repo_root = null, .loading = true, .entries = &.{} },
    })) {
        .ready => |ready| {
            try std.testing.expectEqualStrings("/repo", ready.repo_root);
            try std.testing.expectEqualStrings("src/main.zig", ready.path);
        },
        else => return error.ExpectedStaleFileStageReady,
    }

    const staged_entries = [_]git_status.StatusEntry{.{
        .raw = .{ 'A', ' ' },
        .index = .added,
        .worktree = .unmodified,
        .path = "src/main.zig",
    }};
    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = target,
        .status = .{ .repo_root = "/repo", .loading = false, .entries = &staged_entries },
    })) {
        .already_staged => |path| try std.testing.expectEqualStrings("src/main.zig", path),
        else => return error.ExpectedAlreadyStaged,
    }
}

test "toggleStageTarget keeps stale status strict" {
    switch (toggleStageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = .{ .path = "src/main.zig", .kind = .file },
        .status = .{ .repo_root = "/repo", .loading = true, .entries = &.{} },
    })) {
        .stale_status => {},
        else => return error.ExpectedToggleStaleStatus,
    }
}

test "directory stage and unstage use descendant status entries" {
    const entries = [_]git_status.StatusEntry{
        .{ .raw = .{ ' ', 'M' }, .index = .unmodified, .worktree = .modified, .path = "src/a.zig" },
        .{ .raw = .{ 'A', ' ' }, .index = .added, .worktree = .unmodified, .path = "src/b.zig" },
    };
    const status: StatusSnapshot = .{ .repo_root = "/repo", .loading = false, .entries = &entries };

    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = .{ .path = "src", .kind = .directory },
        .status = status,
    })) {
        .ready => |ready| try std.testing.expectEqual(TargetKind.directory, ready.kind),
        else => return error.ExpectedDirectoryStageReady,
    }

    switch (unstageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = .{ .path = "src", .kind = .directory },
        .status = status,
    })) {
        .ready => |ready| try std.testing.expectEqual(TargetKind.directory, ready.kind),
        else => return error.ExpectedDirectoryUnstageReady,
    }
}

test "pushTarget requires a fresh upstream branch with outgoing commits" {
    const status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 2, .behind = 0 },
    };

    switch (pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = status },
    })) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("feature", target.branch);
            try std.testing.expectEqualStrings("origin", target.remote);
            try std.testing.expectEqualStrings("main", target.remote_branch);
            try std.testing.expectEqualStrings("abc123", target.oid);
            try std.testing.expectEqual(@as(u32, 2), target.ahead);
            try std.testing.expectEqual(@as(u32, 0), target.behind);
        },
        else => return error.ExpectedPushTargetReady,
    }
}

test "pushTarget rejects unsafe or incomplete branch states" {
    const ready_status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 1, .behind = 0 },
    };

    try std.testing.expectEqual(PushTargetResult.unavailable_source, pushTarget(.{
        .source = .stdin,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = ready_status },
    }));
    try std.testing.expectEqual(PushTargetResult.loading_branch_status, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/other", .loading = false, .status = ready_status },
    }));
    try std.testing.expectEqual(PushTargetResult.detached_head, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .detached,
            .upstream = ready_status.upstream,
            .ahead_behind = ready_status.ahead_behind,
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.no_upstream, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.upstream_not_remote_branch, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = .{ .name = "origin", .remote = "origin", .remote_branch = "" },
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.branch_status_unavailable, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.branch_status_unavailable, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.pull_first, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
            .ahead_behind = .{ .ahead = 1, .behind = 1 },
        } },
    }));
    try std.testing.expectEqual(PushTargetResult.nothing_to_push, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
            .ahead_behind = .{ .ahead = 0, .behind = 0 },
        } },
    }));
}
