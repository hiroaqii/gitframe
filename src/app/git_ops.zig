const std = @import("std");
const diff_source = @import("../diff/source.zig");
const file_tree = @import("../file_tree.zig");
const git_branch_status = @import("../git/branch_status.zig");
const git_push = @import("../git/push.zig");
const git_status = @import("../git/status.zig");
const session_hunk_mark = @import("pages/changes/session_hunk_mark.zig");

/// App-local Git operation target classification.
///
/// This module describes what the current UI selection resolved to before a
/// concrete async task is started. Concrete git command execution remains in
/// app/actions.zig.
pub const TargetKind = enum {
    repository,
    file,
    directory,
};

pub const PushMode = git_push.Mode;

/// Trim leading/trailing whitespace from command output before showing it in UI.
pub fn trimGitOutput(message: []const u8) []const u8 {
    return std.mem.trim(u8, message, " \t\r\n");
}

pub fn pushFailureHint(message: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, message, "Permission denied (publickey)") != null) {
        return "SSH publickey authentication failed; check ssh-agent and repository access";
    }
    return null;
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
    label: []const u8 = "",
};

pub const StageTargetResult = union(enum) {
    ready: StageTarget,
    already_staged: []const u8,
    stale_status,
    stale_source,
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
    stale_source,
    conflict_unsupported: PathTarget,
    no_content: PathTarget,
};

pub const inert_hunk_action_message = "hunk actions unavailable for non-UTF-8 diff text";

pub const SessionHunkMarkKey = session_hunk_mark.Key;
pub const SessionHunkMarkMutation = session_hunk_mark.Mutation;

pub const HunkStageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    hunk_index: usize,
    /// Owned patch text returned by target resolution and transferred to the
    /// async task when the request is started.
    patch: []u8,
    session_mark_mutation: SessionHunkMarkMutation,
    reload_after_success: bool = false,

    pub fn deinit(self: *HunkStageTarget, allocator: std.mem.Allocator) void {
        if (self.patch.len > 0) allocator.free(self.patch);
        self.patch = &.{};
    }
};

pub const HunkStageTargetResult = union(enum) {
    ready: HunkStageTarget,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    inert_invalid_utf8,
    offscreen_cursor,
    stale_status,
    stale_source,
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
    inert_invalid_utf8,
    offscreen_cursor,
    not_staged_hunk,
    binary_unsupported,
    unsupported_file_state,
    patch_failed,
    stale_status,
    stale_source,
};

pub const ToggleHunkTargetResult = union(enum) {
    operation: ToggleStageOperation,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    inert_invalid_utf8,
    offscreen_cursor,
    stale_status,
    stale_source,
};

pub const UnstageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    kind: TargetKind,
    label: []const u8 = "",
    /// Fresh status borrowed only until Changes owns the selected index units.
    entries: []const git_status.StatusEntry,
};

pub const UnstageTargetResult = union(enum) {
    ready: UnstageTarget,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    stale_source,
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
    stale_source,
    directory_unsupported,
    conflict_unsupported,
    untracked_unsupported,
    no_unstaged_content,
};

pub const PushTarget = struct {
    mode: PushMode,
    repo_root: []const u8,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    oid: []const u8,
    ahead_behind: ?git_branch_status.AheadBehind,
};

pub const PullTarget = struct {
    repo_root: []const u8,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    upstream_ref: []const u8,
    oid: []const u8,
    ahead: u32,
    behind: u32,
};

pub const FetchTarget = struct {
    repo_root: []const u8,
    remote: []const u8,
};

pub const BranchSwitchTarget = struct {
    repo_root: []const u8,
    branch: []const u8,
    oid: []const u8,
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

pub const PullTargetResult = union(enum) {
    ready: PullTarget,
    unavailable_source,
    no_repo,
    loading_branch_status,
    detached_head,
    branch_unavailable,
    no_upstream,
    upstream_not_remote_branch,
    branch_status_unavailable,
};

pub const FetchTargetResult = union(enum) {
    ready: FetchTarget,
    unavailable_source,
    no_repo,
    loading_branch_status,
    detached_head,
    branch_unavailable,
    no_upstream,
    upstream_not_remote,
};

pub const BranchSwitchTargetResult = union(enum) {
    ready: BranchSwitchTarget,
    detached_head,
    branch_unavailable,
    branch_status_unavailable,
};

pub const StatusSnapshot = struct {
    /// Repo root used by the most recent status load.
    repo_root: ?[]const u8,
    loading: bool,
    fresh: bool = true,
    entries: []const git_status.StatusEntry,

    pub fn entryForPathKey(self: StatusSnapshot, path_key: []const u8) ?git_status.StatusEntry {
        for (self.entries) |entry| {
            const entry_key = entry.canonicalPathKey() orelse continue;
            if (std.mem.eql(u8, entry_key, path_key)) return entry;
        }
        return null;
    }

    pub fn freshEntryForPathKey(self: StatusSnapshot, active_repo_root: []const u8, path_key: []const u8) ?git_status.StatusEntry {
        if (self.loading or !self.fresh) return null;
        const snapshot_root = self.repo_root orelse return null;
        if (!std.mem.eql(u8, snapshot_root, active_repo_root)) return null;
        return self.entryForPathKey(path_key);
    }

    fn isFreshFor(self: StatusSnapshot, active_repo_root: []const u8) bool {
        if (self.loading or !self.fresh) return false;
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
    source_fresh: bool = true,
};

pub const BranchStatusSnapshot = struct {
    repo_root: ?[]const u8,
    loading: bool,
    fresh: bool = true,
    status: git_branch_status.BranchStatus,

    fn freshFor(self: BranchStatusSnapshot, active_repo_root: []const u8) bool {
        if (self.loading or !self.fresh) return false;
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
    const oid = status.oid orelse return .branch_status_unavailable;
    const upstream = status.upstream orelse return .{ .ready = .{
        .mode = .set_upstream,
        .repo_root = repo_root,
        .branch = branch,
        .remote = "origin",
        .remote_branch = branch,
        .oid = oid,
        .ahead_behind = null,
    } };
    if (upstream.remote_branch.len == 0) return .upstream_not_remote_branch;
    const ahead_behind = status.ahead_behind orelse return .branch_status_unavailable;
    if (ahead_behind.behind > 0) return .pull_first;
    if (ahead_behind.ahead == 0) return .nothing_to_push;

    return .{ .ready = .{
        .mode = .upstream,
        .repo_root = repo_root,
        .branch = branch,
        .remote = upstream.remote,
        .remote_branch = upstream.remote_branch,
        .oid = oid,
        .ahead_behind = ahead_behind,
    } };
}

pub fn pullTarget(ctx: RemoteActionContext) PullTargetResult {
    if (!diff_source.sourceAllowsStageProjection(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    if (!ctx.branch_status.freshFor(repo_root)) return .loading_branch_status;

    const branch_status = ctx.branch_status.status;
    const branch = switch (branch_status.head) {
        .branch => |name| name,
        .detached => return .detached_head,
        .unknown => return .branch_unavailable,
    };
    const upstream = branch_status.upstream orelse return .no_upstream;
    if (upstream.remote_branch.len == 0) return .upstream_not_remote_branch;
    const oid = branch_status.oid orelse return .branch_status_unavailable;
    const ahead_behind = branch_status.ahead_behind orelse return .branch_status_unavailable;

    return .{ .ready = .{
        .repo_root = repo_root,
        .branch = branch,
        .remote = upstream.remote,
        .remote_branch = upstream.remote_branch,
        .upstream_ref = upstream.full_ref,
        .oid = oid,
        .ahead = ahead_behind.ahead,
        .behind = ahead_behind.behind,
    } };
}

pub fn fetchTarget(ctx: RemoteActionContext) FetchTargetResult {
    // Fetch only needs a repository and branch status. It does not mutate the
    // worktree, so range views remain eligible here.
    if (!diff_source.sourceRequiresRepo(ctx.source)) return .unavailable_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    if (!ctx.branch_status.freshFor(repo_root)) return .loading_branch_status;

    const branch_status = ctx.branch_status.status;
    switch (branch_status.head) {
        .branch => {},
        .detached => return .detached_head,
        .unknown => return .branch_unavailable,
    }
    const upstream = branch_status.upstream orelse return .no_upstream;
    if (upstream.remote_branch.len == 0) return .upstream_not_remote;

    return .{ .ready = .{
        .repo_root = repo_root,
        .remote = upstream.remote,
    } };
}

/// Validate the branch snapshot supplied by the picker read owner.
pub fn branchSwitchTarget(repo_root: []const u8, branch_status: git_branch_status.BranchStatus) BranchSwitchTargetResult {
    const branch = switch (branch_status.head) {
        .branch => |name| name,
        .detached => return .detached_head,
        .unknown => return .branch_unavailable,
    };
    const oid = branch_status.oid orelse return .branch_status_unavailable;

    return .{ .ready = .{
        .repo_root = repo_root,
        .branch = branch,
        .oid = oid,
    } };
}

pub fn stageTarget(ctx: TargetContext) StageTargetResult {
    if (!diff_source.sourceAllowsStageAction(ctx.source)) return .unavailable_source;
    if (!ctx.source_fresh) return .stale_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    return switch (action_target.kind) {
        .repository => repositoryStageTarget(repo_root, ctx.status),
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
    return .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file, .label = action_target.path } };
}

fn directoryStageTarget(repo_root: []const u8, directory: []const u8, status: StatusSnapshot) StageTargetResult {
    if (!status.isFreshFor(repo_root)) return .stale_status;

    var has_stageable = false;
    for (status.entries) |entry| {
        const key = entry.canonicalPathKey() orelse continue;
        if (!file_tree.isPathDescendantOfDirectory(key, directory)) continue;

        // Git operates on the whole directory path. Reject conflicts here so
        // directory actions cannot resolve them implicitly.
        if (entry.isConflict()) return .{ .conflict_unsupported = directory };

        switch (file_tree.stagePresenceFromEntry(entry)) {
            .untracked, .unstaged_only, .mixed => has_stageable = true,
            .staged_only, .clean_or_unknown, .conflict => {},
        }
    }

    if (!has_stageable) return .{ .no_stageable_content = directory };
    return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory, .label = directory } };
}

fn repositoryStageTarget(repo_root: []const u8, status: StatusSnapshot) StageTargetResult {
    if (!status.isFreshFor(repo_root)) return .stale_status;

    var has_stageable = false;
    for (status.entries) |entry| {
        if (entry.isIgnored()) continue;
        if (entry.isConflict()) return .{ .conflict_unsupported = repoRootLabel(repo_root) };

        switch (file_tree.stagePresenceFromEntry(entry)) {
            .untracked, .unstaged_only, .mixed => has_stageable = true,
            .staged_only, .clean_or_unknown, .conflict => {},
        }
    }

    if (!has_stageable) return .{ .no_stageable_content = repoRootLabel(repo_root) };
    return .{ .ready = .{ .repo_root = repo_root, .path = "", .kind = .repository, .label = repoRootLabel(repo_root) } };
}

pub fn toggleStageTarget(ctx: TargetContext) ToggleStageTargetResult {
    const can_stage = diff_source.sourceAllowsStageAction(ctx.source);
    const can_unstage = diff_source.sourceAllowsUnstageAction(ctx.source);
    if (!can_stage and !can_unstage) return .unavailable_source;
    if (!ctx.source_fresh) return .stale_source;

    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (!ctx.status.isFreshFor(repo_root)) return .stale_status;

    return switch (action_target.kind) {
        .repository => repositoryStageToggleOperation(action_target, can_stage, can_unstage, ctx.status),
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

fn repositoryStageToggleOperation(action_target: PathTarget, can_stage: bool, can_unstage: bool, status: StatusSnapshot) ToggleStageTargetResult {
    var has_unstaged = false;
    var has_staged = false;
    for (status.entries) |entry| {
        if (entry.isIgnored()) continue;
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
    if (!ctx.source_fresh) return .stale_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (!ctx.status.isFreshFor(repo_root)) return .stale_status;
    return switch (action_target.kind) {
        .repository => repositoryUnstageTarget(repo_root, ctx.status),
        .file => fileUnstageTarget(repo_root, action_target, ctx.status),
        .directory => directoryUnstageTarget(repo_root, action_target.path, ctx.status),
    };
}

fn fileUnstageTarget(repo_root: []const u8, action_target: PathTarget, status: StatusSnapshot) UnstageTargetResult {
    const entry = status.entryForPathKey(action_target.path) orelse return .{ .no_staged_content = action_target };
    if (entry.isConflict()) return .{ .conflict_unsupported = action_target };
    if (!entry.isStaged()) return .{ .no_staged_content = action_target };
    return .{ .ready = .{ .repo_root = repo_root, .path = action_target.path, .kind = .file, .label = action_target.path, .entries = status.entries } };
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
    return .{ .ready = .{ .repo_root = repo_root, .path = directory, .kind = .directory, .label = directory, .entries = status.entries } };
}

fn repositoryUnstageTarget(repo_root: []const u8, status: StatusSnapshot) UnstageTargetResult {
    if (!status.isFreshFor(repo_root)) return .stale_status;

    var has_staged = false;
    for (status.entries) |entry| {
        if (entry.isIgnored()) continue;
        if (entry.isConflict()) return .{ .conflict_unsupported = .{ .path = repoRootLabel(repo_root), .kind = .repository } };

        switch (file_tree.stagePresenceFromEntry(entry)) {
            .staged_only, .mixed => has_staged = true,
            .untracked, .unstaged_only, .clean_or_unknown, .conflict => {},
        }
    }

    if (!has_staged) return .{ .no_staged_content = .{ .path = repoRootLabel(repo_root), .kind = .repository } };
    return .{ .ready = .{ .repo_root = repo_root, .path = "", .kind = .repository, .label = repoRootLabel(repo_root), .entries = status.entries } };
}

pub fn discardTarget(ctx: TargetContext) DiscardTargetResult {
    if (!diff_source.sourceAllowsDiscardAction(ctx.source)) return .unavailable_source;
    if (!ctx.source_fresh) return .stale_source;
    const repo_root = ctx.repo_root orelse return .no_repo;
    const action_target = ctx.action_target orelse return .no_path;
    if (action_target.kind == .directory) return .directory_unsupported;
    if (action_target.kind == .repository) return .directory_unsupported;
    const entry = ctx.status.freshEntryForPathKey(repo_root, action_target.path) orelse return .stale_status;
    if (entry.isConflict()) return .conflict_unsupported;
    return switch (file_tree.stagePresenceFromEntry(entry)) {
        .unstaged_only, .mixed => .{ .ready = .{ .repo_root = repo_root, .path = action_target.path } },
        .untracked => .untracked_unsupported,
        .staged_only, .clean_or_unknown, .conflict => .no_unstaged_content,
    };
}

fn repoRootLabel(repo_root: []const u8) []const u8 {
    const base = std.fs.path.basename(repo_root);
    if (base.len == 0) return repo_root;
    return base;
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

test "stale source blocks optimistic file stage and all diff-derived file targets" {
    const target: PathTarget = .{ .path = "src/main.zig", .kind = .file };
    const entries = [_]git_status.StatusEntry{.{
        .raw = .{ 'M', 'M' },
        .index = .modified,
        .worktree = .modified,
        .path = "src/main.zig",
    }};
    const ctx: TargetContext = .{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = target,
        .status = .{ .repo_root = "/repo", .loading = false, .entries = &entries },
        .source_fresh = false,
    };

    try std.testing.expectEqual(StageTargetResult.stale_source, stageTarget(ctx));
    try std.testing.expectEqual(ToggleStageTargetResult.stale_source, toggleStageTarget(ctx));
    try std.testing.expectEqual(UnstageTargetResult.stale_source, unstageTarget(ctx));
    try std.testing.expectEqual(DiscardTargetResult.stale_source, discardTarget(ctx));
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

test "repository stage and unstage scan the whole fresh status snapshot" {
    const entries = [_]git_status.StatusEntry{
        .{ .raw = .{ ' ', 'M' }, .index = .unmodified, .worktree = .modified, .path = "src/a.zig" },
        .{ .raw = .{ 'A', ' ' }, .index = .added, .worktree = .unmodified, .path = "src/b.zig" },
        .{ .raw = .{ '?', '?' }, .index = .untracked, .worktree = .untracked, .path = "README.md" },
    };
    const status: StatusSnapshot = .{ .repo_root = "/work/gitframe", .loading = false, .entries = &entries };

    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/work/gitframe",
        .action_target = .{ .path = "", .kind = .repository },
        .status = status,
    })) {
        .ready => |ready| {
            try std.testing.expectEqual(TargetKind.repository, ready.kind);
            try std.testing.expectEqualStrings("", ready.path);
            try std.testing.expectEqualStrings("gitframe", ready.label);
        },
        else => return error.ExpectedRepositoryStageReady,
    }

    switch (unstageTarget(.{
        .source = .unstaged,
        .repo_root = "/work/gitframe",
        .action_target = .{ .path = "", .kind = .repository },
        .status = status,
    })) {
        .ready => |ready| {
            try std.testing.expectEqual(TargetKind.repository, ready.kind);
            try std.testing.expectEqualStrings("", ready.path);
            try std.testing.expectEqualStrings("gitframe", ready.label);
        },
        else => return error.ExpectedRepositoryUnstageReady,
    }
}

test "repository stage rejects conflicts and no-op snapshots" {
    const conflict_entries = [_]git_status.StatusEntry{
        .{ .raw = .{ 'U', 'U' }, .index = .unmerged, .worktree = .unmerged, .path = "src/conflict.zig" },
    };
    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = .{ .path = "", .kind = .repository },
        .status = .{ .repo_root = "/repo", .loading = false, .entries = &conflict_entries },
    })) {
        .conflict_unsupported => |path| try std.testing.expectEqualStrings("repo", path),
        else => return error.ExpectedRepositoryConflictReject,
    }

    const staged_entries = [_]git_status.StatusEntry{
        .{ .raw = .{ 'A', ' ' }, .index = .added, .worktree = .unmodified, .path = "src/staged.zig" },
    };
    switch (stageTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .action_target = .{ .path = "", .kind = .repository },
        .status = .{ .repo_root = "/repo", .loading = false, .entries = &staged_entries },
    })) {
        .no_stageable_content => |path| try std.testing.expectEqualStrings("repo", path),
        else => return error.ExpectedRepositoryNoStageableContent,
    }
}

test "pushTarget requires a fresh upstream branch with outgoing commits" {
    const status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 2, .behind = 0 },
    };

    switch (pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = status },
    })) {
        .ready => |target| {
            try std.testing.expectEqual(PushMode.upstream, target.mode);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("feature", target.branch);
            try std.testing.expectEqualStrings("origin", target.remote);
            try std.testing.expectEqualStrings("main", target.remote_branch);
            try std.testing.expectEqualStrings("abc123", target.oid);
            try std.testing.expectEqual(@as(u32, 2), target.ahead_behind.?.ahead);
            try std.testing.expectEqual(@as(u32, 0), target.ahead_behind.?.behind);
        },
        else => return error.ExpectedPushTargetReady,
    }
}

test "pushTarget proposes set-upstream push for branch without upstream" {
    const status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature/topic" },
    };

    switch (pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = status },
    })) {
        .ready => |target| {
            try std.testing.expectEqual(PushMode.set_upstream, target.mode);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("feature/topic", target.branch);
            try std.testing.expectEqualStrings("origin", target.remote);
            try std.testing.expectEqualStrings("feature/topic", target.remote_branch);
            try std.testing.expectEqualStrings("abc123", target.oid);
            try std.testing.expect(target.ahead_behind == null);
        },
        else => return error.ExpectedPushTargetReady,
    }
}

test "pullTarget snapshots a fresh upstream branch" {
    const status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 2 },
    };

    switch (pullTarget(.{
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
            try std.testing.expectEqual(@as(u32, 0), target.ahead);
            try std.testing.expectEqual(@as(u32, 2), target.behind);
        },
        else => return error.ExpectedPullTargetReady,
    }
}

test "fetchTarget requires a fresh remote upstream branch" {
    const status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
    };

    switch (fetchTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = status },
    })) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("origin", target.remote);
        },
        else => return error.ExpectedFetchTargetReady,
    }

    switch (fetchTarget(.{
        .source = .{ .range = "main..HEAD" },
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = status },
    })) {
        .ready => |target| try std.testing.expectEqualStrings("origin", target.remote),
        else => return error.ExpectedRangeFetchTargetReady,
    }
}

test "pushFailureHint identifies SSH publickey failures" {
    const message =
        "git@github.com: Permission denied (publickey).\n" ++
        "fatal: Could not read from remote repository.\n";

    try std.testing.expectEqualStrings(
        "SSH publickey authentication failed; check ssh-agent and repository access",
        pushFailureHint(message).?,
    );
    try std.testing.expect(pushFailureHint("fatal: other push failure") == null);
}

test "pushTarget rejects unsafe or incomplete branch states" {
    const ready_status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 1, .behind = 0 },
    };

    try std.testing.expectEqual(PushTargetResult.unavailable_source, pushTarget(.{
        .source = .{ .patch_file = "change.patch" },
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
    switch (pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        } },
    })) {
        .ready => |target| {
            try std.testing.expectEqual(PushMode.set_upstream, target.mode);
            try std.testing.expectEqualStrings("origin", target.remote);
            try std.testing.expectEqualStrings("feature", target.remote_branch);
            try std.testing.expect(target.ahead_behind == null);
        },
        else => return error.ExpectedSetUpstreamPushTargetReady,
    }
    try std.testing.expectEqual(PushTargetResult.upstream_not_remote_branch, pushTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = .{ .name = "origin", .full_ref = "refs/remotes/origin", .remote = "origin", .remote_branch = "" },
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

test "pullTarget requires branch authority before remote refresh" {
    const ready_status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 1 },
    };

    try std.testing.expectEqual(PullTargetResult.unavailable_source, pullTarget(.{
        .source = .{ .patch_file = "change.patch" },
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = ready_status },
    }));
    switch (pullTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
            .ahead_behind = .{ .ahead = 1, .behind = 1 },
        } },
    })) {
        .ready => {},
        else => return error.ExpectedAheadPullTargetReady,
    }
    switch (pullTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = ready_status.upstream,
            .ahead_behind = .{ .ahead = 0, .behind = 0 },
        } },
    })) {
        .ready => {},
        else => return error.ExpectedUpToDatePullTargetReady,
    }
    try std.testing.expectEqual(PullTargetResult.loading_branch_status, pullTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/other", .loading = false, .status = ready_status },
    }));
    var no_upstream = ready_status;
    no_upstream.upstream = null;
    try std.testing.expectEqual(PullTargetResult.no_upstream, pullTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = no_upstream },
    }));
}

test "branchSwitchTarget rejects unsupported branch states" {
    try std.testing.expectEqual(BranchSwitchTargetResult.detached_head, branchSwitchTarget("/repo", .{ .oid = "abc123", .head = .detached }));
    try std.testing.expectEqual(BranchSwitchTargetResult.branch_unavailable, branchSwitchTarget("/repo", .{ .head = .unknown }));
    try std.testing.expectEqual(BranchSwitchTargetResult.branch_status_unavailable, branchSwitchTarget("/repo", .{ .head = .{ .branch = "feature" } }));
    switch (branchSwitchTarget("/repo", .{ .oid = "abc123", .head = .{ .branch = "feature" } })) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("feature", target.branch);
            try std.testing.expectEqualStrings("abc123", target.oid);
        },
        else => return error.ExpectedBranchSwitchTargetReady,
    }
}

test "fetchTarget rejects unsafe or unsupported branch states" {
    const ready_status: git_branch_status.BranchStatus = .{
        .oid = "abc123",
        .head = .{ .branch = "feature" },
        .upstream = .{ .name = "origin/main", .full_ref = "refs/remotes/origin/main", .remote = "origin", .remote_branch = "main" },
    };

    try std.testing.expectEqual(FetchTargetResult.unavailable_source, fetchTarget(.{
        .source = .{ .patch_file = "change.patch" },
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = ready_status },
    }));
    try std.testing.expectEqual(FetchTargetResult.loading_branch_status, fetchTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/other", .loading = false, .status = ready_status },
    }));
    try std.testing.expectEqual(FetchTargetResult.detached_head, fetchTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .detached,
            .upstream = ready_status.upstream,
        } },
    }));
    try std.testing.expectEqual(FetchTargetResult.no_upstream, fetchTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
        } },
    }));
    try std.testing.expectEqual(FetchTargetResult.upstream_not_remote, fetchTarget(.{
        .source = .unstaged,
        .repo_root = "/repo",
        .branch_status = .{ .repo_root = "/repo", .loading = false, .status = .{
            .oid = "abc123",
            .head = .{ .branch = "feature" },
            .upstream = .{ .name = "origin", .full_ref = "refs/remotes/origin", .remote = "origin", .remote_branch = "" },
        } },
    }));
}
