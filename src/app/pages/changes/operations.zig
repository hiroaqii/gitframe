//! Changes-local action target and authority resolution.
//!
//! Target classification is borrowed and synchronous. Before an operation can
//! outlive that classification, this module clones it into an immutable owned
//! proposal. App remains responsible for overlays, editable/secret input, pending
//! process ownership, and transferring the proposal into an async task payload.

const std = @import("std");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const builtin = @import("builtin");
const authority = @import("../../diff_surface/authority.zig");
const navigation = @import("navigation.zig");
const content_selection = @import("../../diff_surface/selection.zig");
const changes_page = @import("../changes.zig");
const app_actions = @import("../../actions.zig");
const git_ops = @import("../../git_ops.zig");
const changes_projection = @import("../../changes_projection.zig");
const projection_component = @import("../../projection_component.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_patch = @import("../../../diff/patch.zig");
const diff_source = @import("../../../diff/source.zig");
const auto_reload = @import("../../auto_reload.zig");
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const remote_request = @import("../../remote_request.zig");
const action_fence = @import("action_fence.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

const ToggleHunkTargetResult = git_ops.ToggleHunkTargetResult;
const HunkStageTargetResult = git_ops.HunkStageTargetResult;
const HunkUnstageTargetResult = git_ops.HunkUnstageTargetResult;

pub const OwnedDiscardProposal = struct {
    repo_root: []u8,
    path: []u8,

    fn deinit(self: *OwnedDiscardProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const OwnedPathProposal = struct {
    repo_root: []u8,
    path: []u8,
    label: []u8,
    kind: git_ops.TargetKind,

    fn deinit(self: *OwnedPathProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const OwnedHunkProposal = struct {
    repo_root: []u8,
    path: []u8,
    hunk_index: usize,
    patch: []u8,
    session_mark_mutation: git_ops.SessionHunkMarkMutation,
    reload_after_success: bool,

    fn deinit(self: *OwnedHunkProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        if (self.patch.len > 0) allocator.free(self.patch);
        self.* = undefined;
    }
};

pub const OwnedPushProposal = struct {
    repository_identity: remote_request.RepositoryIdentity,
    mode: git_ops.PushMode,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    ahead_behind: ?@import("../../../git/branch_status.zig").AheadBehind,

    fn deinit(self: *OwnedPushProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

pub const OwnedPullProposal = struct {
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    ahead: u32,
    behind: u32,

    fn deinit(self: *OwnedPullProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

pub const OwnedFetchProposal = struct {
    repo_root: []u8,
    remote: []u8,

    fn deinit(self: *OwnedFetchProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.remote);
        self.* = undefined;
    }
};

/// Immutable operation snapshots transferred from Changes to shell-owned UI or
/// task orchestration. Shell code consumes one proposal or calls `deinit`; it
/// never borrows Changes state while a confirmation or async operation is live.
pub const OwnedOperationProposal = union(enum) {
    stage_file: OwnedPathProposal,
    unstage_file: OwnedPathProposal,
    stage_hunk: OwnedHunkProposal,
    unstage_hunk: OwnedHunkProposal,
    discard: OwnedDiscardProposal,
    push: OwnedPushProposal,
    pull: OwnedPullProposal,
    fetch: OwnedFetchProposal,

    pub fn deinit(self: *OwnedOperationProposal, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*proposal| proposal.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ReloadIntent = action_fence.ReloadIntent;

pub const AcceptedActionOutcome = union(enum) {
    stage_file,
    unstage_file,
    discard_file: struct { repo_root: []const u8, path: []const u8 },
    stage_hunk: struct {
        repo_root: []const u8,
        path: []const u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,
    },
    unstage_hunk: struct {
        repo_root: []const u8,
        path: []const u8,
        hunk_index: usize,
        session_mark_mutation: git_ops.SessionHunkMarkMutation,
        reload_after_success: bool,
    },
    commit: struct { repo_root: []const u8 },
    switch_branch: struct { repo_root: []const u8 },
    stash: struct { repo_root: []const u8 },
};

pub const OutcomeApply = struct {
    reload: ReloadIntent = .none,
    local_effect_failure: ?LocalEffectFailure = null,
};

/// A Git side effect has already succeeded when these local presentation
/// mutations run. Their failure may affect a diagnostic or an ephemeral mark,
/// but must never suppress the mandatory reload which reconciles Git state.
pub const LocalEffectFailure = enum {
    reviewed_mark_clear,
    staged_hunk_mark_record,
};

pub const CommitSummary = union(enum) {
    unavailable,
    loading_or_stale,
    ready: struct { count: usize },
};

pub const StashTarget = struct {
    repo_root: []const u8,
    branch: ?[]const u8,
    oid: []const u8,
    has_all: bool,
    has_staged: bool,
};

pub const View = struct {
    page: *const changes_page.ChangesPageState,
    navigation: navigation.View,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    activation_state: authority.ActivationState,

    /// Git operation authority is stricter than page activation lifetime. The
    /// old Changes body and activation remain visible while a mutation runs,
    /// but that visual owner must not resolve another file/hunk or remote
    /// action until exact-terminal reconciliation reopens repository reads.
    pub fn activation(self: View) authority.ActivationState {
        if (!self.page.repository_read_authority.mayStartRepositoryRead()) return .inactive;
        return self.activation_state;
    }

    fn currentContentToken(self: View) ?content_selection.ContentToken {
        return self.navigation.currentContentToken();
    }

    fn sessionHunkMarkKey(self: View, display_hunk_index: usize) ?git_ops.SessionHunkMarkKey {
        return .{
            .content = self.currentContentToken() orelse return null,
            .display_hunk_index = display_hunk_index,
        };
    }

    pub fn selectedSidebarActionTarget(self: View) ?git_ops.PathTarget {
        const loaded = self.navigation.activeLoadedDiffConst() orelse {
            const path = self.navigation.selectedStagePathKey() orelse return null;
            return .{ .path = path, .kind = .file };
        };
        if (self.page.viewer.selected_node >= loaded.tree.nodes.len) return null;

        // Directory rows intentionally retain the previous diff target. Git
        // operations resolve against the sidebar cursor instead.
        const node = loaded.tree.nodes[self.page.viewer.selected_node];
        return switch (node.target) {
            .repo_root => .{ .path = "", .kind = .repository },
            .directory => |path| .{ .path = if (path.len > 0) path else node.path, .kind = .directory },
            .diff_file, .status_entry => if (node.path_key.len > 0) .{
                .path = node.path_key,
                .kind = .file,
            } else null,
        };
    }

    pub fn targetContext(self: View, action: authority.Action) git_ops.TargetContext {
        const members = self.activationMembers();
        const requirements = action.requirements();
        return .{
            .source = self.source,
            .repo_root = self.repo_root,
            .action_target = self.selectedSidebarActionTarget(),
            .status = .{
                .repo_root = self.page.git_status.repo_root,
                .loading = requirements.status != .unused and members.status == .pending,
                .fresh = members.status.satisfies(requirements.status),
                .entries = self.page.git_status.document.entries,
            },
            .source_fresh = members.source.satisfies(requirements.source),
        };
    }

    pub fn stageTarget(self: View) git_ops.StageTargetResult {
        return git_ops.stageTarget(self.targetContext(.stage_file));
    }

    pub fn toggleStageTarget(self: View) git_ops.ToggleStageTargetResult {
        return git_ops.toggleStageTarget(self.targetContext(.stage_file));
    }

    pub fn unstageTarget(self: View) git_ops.UnstageTargetResult {
        return git_ops.unstageTarget(self.targetContext(.unstage_file));
    }

    pub fn discardTarget(self: View) git_ops.DiscardTargetResult {
        return git_ops.discardTarget(self.targetContext(.discard_file));
    }

    pub fn pushTarget(self: View) git_ops.PushTargetResult {
        const members = self.activationMembers();
        const requirements = authority.Action.push.requirements();
        return git_ops.pushTarget(.{
            .source = self.source,
            .repo_root = self.repo_root,
            .branch_status = .{
                .repo_root = self.page.branch_status.repo_root,
                .loading = requirements.branch != .unused and members.branch == .pending,
                .fresh = members.branch.satisfies(requirements.branch),
                .status = self.page.branch_status.status,
            },
        });
    }

    pub fn pullTarget(self: View) git_ops.PullTargetResult {
        const members = self.activationMembers();
        const requirements = authority.Action.pull.requirements();
        return git_ops.pullTarget(.{
            .source = self.source,
            .repo_root = self.repo_root,
            .branch_status = .{
                .repo_root = self.page.branch_status.repo_root,
                .loading = requirements.branch != .unused and members.branch == .pending,
                .fresh = members.branch.satisfies(requirements.branch),
                .status = self.page.branch_status.status,
            },
            .status = .{
                .repo_root = self.page.git_status.repo_root,
                .loading = requirements.status != .unused and members.status == .pending,
                .fresh = members.status.satisfies(requirements.status),
                .entries = self.page.git_status.document.entries,
            },
        });
    }

    pub fn fetchTarget(self: View) git_ops.FetchTargetResult {
        const members = self.activationMembers();
        const requirements = authority.Action.fetch.requirements();
        return git_ops.fetchTarget(.{
            .source = self.source,
            .repo_root = self.repo_root,
            .branch_status = .{
                .repo_root = self.page.branch_status.repo_root,
                .loading = requirements.branch != .unused and members.branch == .pending,
                .fresh = members.branch.satisfies(requirements.branch),
                .status = self.page.branch_status.status,
            },
        });
    }

    pub fn canOpenCommitPanel(self: View) bool {
        return diff_source.sourceAllowsStageProjection(self.source) and self.repo_root != null;
    }

    pub fn commitSummary(self: View) CommitSummary {
        if (!diff_source.sourceAllowsStageProjection(self.source)) return .unavailable;
        if (!self.activation().satisfiesAction(.commit)) return .loading_or_stale;
        const active_root = self.repo_root orelse return .unavailable;
        const snapshot_root = self.page.git_status.repo_root orelse return .unavailable;
        if (!std.mem.eql(u8, active_root, snapshot_root)) return .loading_or_stale;

        var count: usize = 0;
        for (self.page.git_status.document.entries) |entry| {
            if (entry.isStaged()) count += 1;
        }
        return .{ .ready = .{ .count = count } };
    }

    pub fn stashTarget(self: View, allow_refreshing: bool) ?StashTarget {
        if (!diff_source.sourceAllowsStageProjection(self.source)) return null;
        const active = self.activation();
        if (!active.satisfiesAction(.create_stash)) {
            if (!allow_refreshing) return null;
            const members = active.members() orelse return null;
            // An open dialog keeps its last-good inputs during ordinary reloads.
            // The worker revalidates the branch and scope before any mutation.
            if (members.status != .fresh and members.status != .pending) return null;
            if (members.branch != .fresh and members.branch != .pending) return null;
        }
        const root = self.repo_root orelse return null;
        if (!std.mem.eql(u8, root, self.page.git_status.repo_root orelse return null)) return null;
        if (!std.mem.eql(u8, root, self.page.branch_status.repo_root orelse return null)) return null;
        const branch = self.page.branch_status.status;
        if (branch.head == .unknown) return null;
        return .{
            .repo_root = root,
            .branch = branch.branchName(),
            .oid = branch.oid orelse return null,
            .has_all = @import("../../../git/stash.zig").hasChanges(self.page.git_status.document, .all),
            .has_staged = @import("../../../git/stash.zig").hasChanges(self.page.git_status.document, .staged),
        };
    }

    pub fn ownDiscardProposal(_: View, allocator: std.mem.Allocator, target: git_ops.DiscardTarget) !OwnedOperationProposal {
        const repo_root = try allocator.dupe(u8, target.repo_root);
        errdefer allocator.free(repo_root);
        return .{ .discard = .{
            .repo_root = repo_root,
            .path = try allocator.dupe(u8, target.path),
        } };
    }

    pub fn ownStageFileProposal(_: View, allocator: std.mem.Allocator, target: git_ops.StageTarget) !OwnedOperationProposal {
        return .{ .stage_file = try clonePathProposal(allocator, target.repo_root, target.path, target.label, target.kind) };
    }

    pub fn ownUnstageFileProposal(_: View, allocator: std.mem.Allocator, target: git_ops.UnstageTarget) !OwnedOperationProposal {
        return .{ .unstage_file = try clonePathProposal(allocator, target.repo_root, target.path, target.label, target.kind) };
    }

    pub fn ownStageHunkProposal(_: View, allocator: std.mem.Allocator, target: *git_ops.HunkStageTarget) !OwnedOperationProposal {
        return .{ .stage_hunk = try consumeHunkProposal(allocator, target) };
    }

    pub fn ownUnstageHunkProposal(_: View, allocator: std.mem.Allocator, target: *git_ops.HunkUnstageTarget) !OwnedOperationProposal {
        return .{ .unstage_hunk = try consumeHunkProposal(allocator, target) };
    }

    pub fn ownPushProposal(
        _: View,
        allocator: std.mem.Allocator,
        repository_identity: remote_request.RepositoryIdentity,
        target: git_ops.PushTarget,
    ) !OwnedOperationProposal {
        return .{ .push = try clonePushProposal(allocator, repository_identity, target) };
    }

    pub fn ownPullProposal(_: View, allocator: std.mem.Allocator, target: git_ops.PullTarget) !OwnedOperationProposal {
        return .{ .pull = try clonePullProposal(allocator, target) };
    }

    pub fn ownFetchProposal(_: View, allocator: std.mem.Allocator, target: git_ops.FetchTarget) !OwnedOperationProposal {
        const repo_root = try allocator.dupe(u8, target.repo_root);
        errdefer allocator.free(repo_root);
        return .{ .fetch = .{
            .repo_root = repo_root,
            .remote = try allocator.dupe(u8, target.remote),
        } };
    }

    pub fn selectedHunkToggleOperation(self: View) ToggleHunkTargetResult {
        switch (self.navigation.hunkInteractionAvailability()) {
            .available => {},
            .inert_invalid_utf8 => return .inert_invalid_utf8,
            .unavailable => return .no_hunk,
        }
        if (!self.displayedProjectionReadIsFresh()) return .stale_status;
        const can_stage = diff_source.sourceAllowsStageAction(self.source);
        const can_unstage = diff_source.sourceAllowsUnstageAction(self.source);
        if (!can_stage and !can_unstage) return .unavailable_source;
        if (!self.activation().satisfiesAction(.stage_hunk)) return self.hunkAuthorityFailure(.stage_hunk);

        const repo_root = self.repo_root orelse return .no_repo;
        if (self.currentHunkAuthority()) |bundle| {
            if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
            const projected_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
            const stage_states = bundle.hunkStageStates();
            if (projected_index >= stage_states.len) return .no_hunk;
            return switch (stage_states[projected_index]) {
                .unstaged => if (can_stage) .{ .operation = .stage } else .unavailable_source,
                .staged => if (can_unstage) .{ .operation = .unstage } else .unavailable_source,
            };
        }
        if (self.navigation.activeHunkAuthority() != null) return .stale_status;

        const cached_authority = self.selectedHunkUsesCachedProjection();
        const file = if (cached_authority)
            self.navigation.displayedDiffFile() orelse return .no_file
        else
            self.navigation.selectedFile() orelse return .no_file;
        const path = diff_file.canonicalPathKey(file) orelse return .no_path;
        if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
        const hunk_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        if (file.hunks.len == 0 or hunk_index >= file.hunks.len) return .no_hunk;

        if (cached_authority) {
            return if (can_unstage) .{ .operation = .unstage } else .unavailable_source;
        }

        const mark_key = self.sessionHunkMarkKey(hunk_index) orelse return .stale_source;
        if (self.page.staged_hunks.containsExact(repo_root, path, mark_key)) {
            return if (can_unstage) .{ .operation = .unstage } else .unavailable_source;
        }
        return if (can_stage) .{ .operation = .stage } else .unavailable_source;
    }

    pub fn selectedHunkStageTarget(self: View, allocator: std.mem.Allocator) HunkStageTargetResult {
        switch (self.navigation.hunkInteractionAvailability()) {
            .available => {},
            .inert_invalid_utf8 => return .inert_invalid_utf8,
            .unavailable => return .no_hunk,
        }
        if (!self.displayedProjectionReadIsFresh()) return .stale_status;
        if (!diff_source.sourceAllowsStageAction(self.source)) return .unavailable_source;
        if (!self.activation().satisfiesAction(.stage_hunk)) return switch (self.hunkAuthorityFailure(.stage_hunk)) {
            .stale_status => .stale_status,
            else => .stale_source,
        };
        const repo_root = self.repo_root orelse return .no_repo;
        if (self.currentHunkAuthority()) |bundle| {
            return self.selectedProjectedHunkStageTarget(allocator, repo_root, bundle);
        }
        if (self.navigation.activeHunkAuthority() != null) return .stale_status;
        const cached_authority = self.selectedHunkUsesCachedProjection();
        const file = if (cached_authority)
            self.navigation.displayedDiffFile() orelse return .no_file
        else
            self.navigation.selectedFile() orelse return .no_file;
        const path = diff_file.canonicalPathKey(file) orelse return .no_path;
        if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
        const hunk_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        if (file.hunks.len == 0 or hunk_index >= file.hunks.len) return .no_hunk;
        const entry = self.navigation.freshStatusEntryForPathKey(repo_root, path) orelse return .stale_status;
        if (entry.isConflict()) return .conflict_unsupported;
        if (file.is_binary) return .binary_unsupported;
        if (diff_file.status(file) != .modified or diff_file.hasModeChange(file)) return .unsupported_file_state;
        if (cached_authority) return .already_staged_hunk;
        const mark_key = self.sessionHunkMarkKey(hunk_index) orelse return .stale_source;
        if (self.page.staged_hunks.containsExact(repo_root, path, mark_key)) return .already_staged_hunk;

        const patch = diff_patch.formatSingleHunkPatch(allocator, file, hunk_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = hunk_index,
            .patch = patch,
            .session_mark_mutation = .{ .add = mark_key },
        } };
    }

    pub fn selectedHunkUnstageTarget(self: View, allocator: std.mem.Allocator) HunkUnstageTargetResult {
        switch (self.navigation.hunkInteractionAvailability()) {
            .available => {},
            .inert_invalid_utf8 => return .inert_invalid_utf8,
            .unavailable => return .no_hunk,
        }
        if (!self.displayedProjectionReadIsFresh()) return .stale_status;
        if (!diff_source.sourceAllowsUnstageAction(self.source)) return .unavailable_source;
        if (!self.activation().satisfiesAction(.unstage_hunk)) return switch (self.hunkAuthorityFailure(.unstage_hunk)) {
            .stale_status => .stale_status,
            else => .stale_source,
        };
        const repo_root = self.repo_root orelse return .no_repo;
        if (self.currentHunkAuthority()) |bundle| {
            return self.selectedProjectedHunkUnstageTarget(allocator, repo_root, bundle);
        }
        if (self.navigation.activeHunkAuthority() != null) return .stale_status;
        const cached_authority = self.selectedHunkUsesCachedProjection();
        const file = if (cached_authority)
            self.navigation.displayedDiffFile() orelse return .no_file
        else
            self.navigation.selectedFile() orelse return .no_file;
        const path = diff_file.canonicalPathKey(file) orelse return .no_path;
        if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
        const hunk_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        if (file.hunks.len == 0 or hunk_index >= file.hunks.len) return .no_hunk;
        if (file.is_binary) return .binary_unsupported;
        if (diff_file.status(file) != .modified or diff_file.hasModeChange(file)) return .unsupported_file_state;
        const mark_key = if (cached_authority)
            null
        else
            self.sessionHunkMarkKey(hunk_index) orelse return .stale_source;
        if (mark_key) |key| {
            if (!self.page.staged_hunks.containsExact(repo_root, path, key)) return .not_staged_hunk;
        }

        // Ordinary unstaged content may reverse only the exact local mark
        // captured from this presentation. Cached content has no such mark;
        // its accepted result instead requests the existing source-and-aux
        // reload. Completion never re-resolves the then-current cursor.
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, hunk_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = hunk_index,
            .patch = patch,
            .session_mark_mutation = if (mark_key) |key| .{ .remove = key } else .none,
            .reload_after_success = cached_authority,
        } };
    }

    fn selectedHunkUsesCachedProjection(self: View) bool {
        _ = self.navigation.activeCachedDiffProjection() orelse return false;
        const request = self.page.changes_projection.displayed.request() orelse return false;
        return request.kind == .cached_diff and
            request.status_snapshot_revision == self.page.status_snapshot_revision;
    }

    fn selectedProjectedHunkStageTarget(
        self: View,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        bundle: navigation.ActiveHunkAuthority,
    ) HunkStageTargetResult {
        const path = diff_file.canonicalPathKey(bundle.display_file) orelse return .no_path;
        if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
        const projected_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        const stage_states = bundle.hunkStageStates();
        const action_origins = bundle.hunkActionOrigins();
        if (projected_index >= stage_states.len or projected_index >= action_origins.len) return .no_hunk;
        if (stage_states[projected_index] == .staged) return .already_staged_hunk;
        const origin = action_origins[projected_index];
        const origin_index = switch (origin) {
            .unstaged => |index| index,
            .cached => return .no_hunk,
        };
        const file = bundle.actionSourceFile(origin) orelse return .no_file;
        if (origin_index >= file.hunks.len) return .no_hunk;
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, origin_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = projected_index,
            .patch = patch,
            .session_mark_mutation = .none,
        } };
    }

    fn selectedProjectedHunkUnstageTarget(
        self: View,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        bundle: navigation.ActiveHunkAuthority,
    ) HunkUnstageTargetResult {
        const path = diff_file.canonicalPathKey(bundle.display_file) orelse return .no_path;
        if (!self.navigation.diffCursorIsVisible()) return .offscreen_cursor;
        const projected_index = self.navigation.selectedHunkIndex() orelse return .no_hunk;
        const stage_states = bundle.hunkStageStates();
        const action_origins = bundle.hunkActionOrigins();
        if (projected_index >= stage_states.len or projected_index >= action_origins.len) return .no_hunk;
        if (stage_states[projected_index] == .unstaged) return .not_staged_hunk;
        const origin = action_origins[projected_index];
        const origin_index = switch (origin) {
            .cached => |index| index,
            .unstaged => return .no_hunk,
        };
        const file = bundle.actionSourceFile(origin) orelse return .no_file;
        if (origin_index >= file.hunks.len) return .no_hunk;
        const mark_key = self.sessionHunkMarkKey(projected_index);
        const session_mark_mutation: git_ops.SessionHunkMarkMutation = if (mark_key) |key|
            if (self.page.staged_hunks.containsExact(repo_root, path, key)) .{ .remove = key } else .none
        else
            .none;
        const patch = diff_patch.formatSingleHunkPatch(allocator, file, origin_index) catch |err| switch (err) {
            error.BinaryFile => return .binary_unsupported,
            error.UnsupportedFileState => return .unsupported_file_state,
            error.NoPath => return .no_path,
            error.InvalidHunk => return .no_hunk,
            error.OutOfMemory => return .patch_failed,
        };
        return .{ .ready = .{
            .repo_root = repo_root,
            .path = path,
            .hunk_index = projected_index,
            .patch = patch,
            .session_mark_mutation = session_mark_mutation,
        } };
    }

    fn currentHunkAuthority(self: View) ?navigation.ActiveHunkAuthority {
        if (!self.activation().satisfiesAction(.stage_hunk)) return null;
        const bundle = self.navigation.activeHunkAuthority() orelse return null;
        const request = self.page.changes_projection.displayed.request() orelse return null;
        if (request.kind != bundle.authority.requestKind() or
            request.status_snapshot_revision != self.page.status_snapshot_revision) return null;
        if (bundle.authority.statusSnapshotRevision() != self.page.status_snapshot_revision) return null;
        return bundle;
    }

    /// A superseded projection may remain visible while mutation reconciliation
    /// is in flight, but it must not supply another Git patch. Unrelated retained
    /// projections do not govern the currently displayed primary body.
    fn displayedProjectionReadIsFresh(self: View) bool {
        const request = self.page.changes_projection.displayed.request() orelse return true;
        if (!self.navigation.displayedProjectionRequestIsActive(request.*)) return true;
        return self.page.repository_read_authority.acceptsRead(request.read_epoch);
    }

    fn activationMembers(self: View) authority.MemberVector {
        return self.activation().members() orelse .{
            .source = .unavailable,
            .status = .unavailable,
            .branch = .unavailable,
        };
    }

    fn hunkAuthorityFailure(self: View, action: authority.Action) ToggleHunkTargetResult {
        const requirements = action.requirements();
        const members = self.activationMembers();
        if (!members.source.satisfies(requirements.source)) return .stale_source;
        return .stale_status;
    }
};

pub const Controller = struct {
    page: *changes_page.ChangesPageState,
    navigation: navigation.Controller,
    view_state: View,

    pub fn view(self: Controller) View {
        return self.view_state;
    }

    fn applySessionHunkMarkMutation(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        path: []const u8,
        mutation: git_ops.SessionHunkMarkMutation,
    ) bool {
        return switch (mutation) {
            .none => false,
            .add => |key| blk: {
                const current = self.view_state.currentContentToken() orelse break :blk false;
                if (!current.eql(key.content)) break :blk false;
                self.page.staged_hunks.addExact(allocator, repo_root, path, key) catch break :blk true;
                break :blk false;
            },
            .remove => |key| blk: {
                _ = self.page.staged_hunks.removeExact(allocator, repo_root, path, key);
                break :blk false;
            },
        };
    }

    /// Applies only Changes-local consequences of an already accepted shell
    /// action result. Process pending state, diagnostics, and task spawning stay
    /// with the shell; the returned reload intent is executed after this call.
    pub fn applyAcceptedOutcome(
        self: Controller,
        allocator: std.mem.Allocator,
        outcome: AcceptedActionOutcome,
        active_repo_matches: bool,
    ) OutcomeApply {
        return switch (outcome) {
            .stash => |value| blk: {
                self.page.staged_hunks.clearRepo(allocator, value.repo_root);
                if (active_repo_matches) self.navigation.clearActionCursor(allocator);
                break :blk .{ .reload = if (active_repo_matches) .source_and_aux else .none };
            },
            .stage_file => blk: {
                if (!active_repo_matches) break :blk .{};
                break :blk .{ .reload = .source_and_aux };
            },
            .unstage_file => blk: {
                if (!active_repo_matches) break :blk .{};
                break :blk .{ .reload = .source_and_aux };
            },
            .discard_file => |value| blk: {
                const clear_failed = if (self.page.reviewed_store.clearPathKey(allocator, value.repo_root, value.path)) |_| false else |_| true;
                break :blk .{
                    .reload = if (active_repo_matches) .source_and_aux else .none,
                    .local_effect_failure = if (clear_failed) .reviewed_mark_clear else null,
                };
            },
            .stage_hunk => |value| blk: {
                if (!active_repo_matches) break :blk .{};
                const mark_failed = self.applySessionHunkMarkMutation(
                    allocator,
                    value.repo_root,
                    value.path,
                    value.session_mark_mutation,
                );
                break :blk .{
                    .reload = .{ .status = value.repo_root },
                    .local_effect_failure = if (mark_failed) .staged_hunk_mark_record else null,
                };
            },
            .unstage_hunk => |value| blk: {
                if (!active_repo_matches) break :blk .{};
                _ = self.applySessionHunkMarkMutation(
                    allocator,
                    value.repo_root,
                    value.path,
                    value.session_mark_mutation,
                );
                if (value.reload_after_success) {
                    break :blk .{ .reload = .source_and_aux };
                }
                break :blk .{ .reload = .{ .status = value.repo_root } };
            },
            .commit => |value| blk: {
                const clear_failed = if (self.page.reviewed_store.clearForRepo(allocator, value.repo_root)) |_| false else |_| true;
                break :blk .{
                    .reload = if (active_repo_matches) .source_and_aux else .none,
                    .local_effect_failure = if (clear_failed) .reviewed_mark_clear else null,
                };
            },
            .switch_branch => |value| blk: {
                const clear_failed = if (self.page.reviewed_store.clearForRepo(allocator, value.repo_root)) |_| false else |_| true;
                self.page.staged_hunks.clearRepo(allocator, value.repo_root);
                if (active_repo_matches) {
                    self.navigation.clearActionCursor(allocator);
                    self.navigation.clearSearch();
                }
                break :blk .{
                    .reload = if (active_repo_matches) .source_and_aux_clear_visible else .none,
                    .local_effect_failure = if (clear_failed) .reviewed_mark_clear else null,
                };
            },
        };
    }
};

fn clonePushProposal(
    allocator: std.mem.Allocator,
    repository_identity: remote_request.RepositoryIdentity,
    target: git_ops.PushTarget,
) !OwnedPushProposal {
    const repo_root = try allocator.dupe(u8, target.repo_root);
    errdefer allocator.free(repo_root);
    const branch = try allocator.dupe(u8, target.branch);
    errdefer allocator.free(branch);
    const remote = try allocator.dupe(u8, target.remote);
    errdefer allocator.free(remote);
    const remote_branch = try allocator.dupe(u8, target.remote_branch);
    errdefer allocator.free(remote_branch);
    return .{
        .repository_identity = repository_identity,
        .mode = target.mode,
        .repo_root = repo_root,
        .branch = branch,
        .remote = remote,
        .remote_branch = remote_branch,
        .oid = try allocator.dupe(u8, target.oid),
        .ahead_behind = target.ahead_behind,
    };
}

fn clonePathProposal(
    allocator: std.mem.Allocator,
    repo_root_value: []const u8,
    path_value: []const u8,
    label_value: []const u8,
    kind: git_ops.TargetKind,
) !OwnedPathProposal {
    const repo_root = try allocator.dupe(u8, repo_root_value);
    errdefer allocator.free(repo_root);
    const path = try allocator.dupe(u8, path_value);
    errdefer allocator.free(path);
    return .{
        .repo_root = repo_root,
        .path = path,
        .label = try allocator.dupe(u8, if (label_value.len > 0) label_value else path_value),
        .kind = kind,
    };
}

fn consumeHunkProposal(allocator: std.mem.Allocator, target: *git_ops.HunkStageTarget) !OwnedHunkProposal {
    defer {
        if (target.patch.len > 0) allocator.free(target.patch);
        target.patch = &.{};
    }
    const repo_root = try allocator.dupe(u8, target.repo_root);
    errdefer allocator.free(repo_root);
    const path = try allocator.dupe(u8, target.path);
    errdefer allocator.free(path);
    const patch = target.patch;
    target.patch = &.{};
    return .{
        .repo_root = repo_root,
        .path = path,
        .hunk_index = target.hunk_index,
        .patch = patch,
        .session_mark_mutation = target.session_mark_mutation,
        .reload_after_success = target.reload_after_success,
    };
}

fn clonePullProposal(allocator: std.mem.Allocator, target: git_ops.PullTarget) !OwnedPullProposal {
    const repo_root = try allocator.dupe(u8, target.repo_root);
    errdefer allocator.free(repo_root);
    const branch = try allocator.dupe(u8, target.branch);
    errdefer allocator.free(branch);
    const remote = try allocator.dupe(u8, target.remote);
    errdefer allocator.free(remote);
    const remote_branch = try allocator.dupe(u8, target.remote_branch);
    errdefer allocator.free(remote_branch);
    return .{
        .repo_root = repo_root,
        .branch = branch,
        .remote = remote,
        .remote_branch = remote_branch,
        .oid = try allocator.dupe(u8, target.oid),
        .ahead = target.ahead,
        .behind = target.behind,
    };
}

test "Changes raw diff paths reach the Git index without touching namesakes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const git_command = @import("../../../git/command.zig");
    const git_read = @import("../../../git/read.zig");
    const backend = @import("../../../git/operations.zig");
    const parser = @import("../../../diff/parser.zig");
    const file_tree = @import("../../../file_tree.zig");
    const git_status = @import("../../../git/status.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "trailing.txt ", "日本\t.txt", "choice*.txt", "mode.txt", "binary.dat", "a/victim", "b/victim" };
    const init = try pathTestCommand(tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    allocator.free(init);
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    for (names ++ .{ "choice-other.txt", "rename-old.txt" }) |name|
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "config", "core.fileMode", "true" },
        &.{ "git", "config", "core.quotePath", "true" },
        &.{ "git", "add", "--all" },
        &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" },
    }) |argv| allocator.free(try pathTestCommand(tmp.dir, argv));
    try tmp.dir.writeFile(io, .{ .sub_path = "trailing.txt", .data = "UNTRACKED namesake\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "choice-other.txt", .data = "CANARY staged\n" });
    allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "add", "--", "choice-other.txt" }));
    try tmp.dir.writeFile(io, .{ .sub_path = "choice-other.txt", .data = "CANARY worktree\n" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const git_context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    for (names) |name| {
        const mode_only = std.mem.eql(u8, name, "mode.txt");
        const expected = if (mode_only) "base\n" else if (std.mem.eql(u8, name, "binary.dat")) "changed\x00binary\n" else "selected\n";
        if (mode_only) {
            allocator.free(try pathTestCommand(tmp.dir, &.{ "chmod", "+x", name }));
        } else {
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = expected });
        }
        const raw_diff = try git_read.loadDiff(allocator, io, .{ .context = git_context, .kind = .unstaged });
        defer raw_diff.deinit(allocator);
        try std.testing.expect(raw_diff == .ok);
        const raw_status = try git_read.loadStatus(allocator, io, .{ .context = git_context });
        defer raw_status.deinit(allocator);
        try std.testing.expect(raw_status == .ok);
        var status = try git_status.StatusBundle.parseOwned(allocator, raw_status.ok);
        defer status.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const document = try parser.parse(arena.allocator(), raw_diff.ok);
        const tree = try file_tree.buildWithStatus(arena.allocator(), document, status.document);
        var selected_node: ?usize = null;
        for (tree.nodes, 0..) |node, index| {
            if (node.kind != .file or !std.mem.eql(u8, node.path_key, name)) continue;
            try std.testing.expect(selected_node == null); // diff/status merge yields one row
            selected_node = index;
        }
        const node = tree.nodes[selected_node.?];
        try std.testing.expect(node.target == .diff_file);
        const file = document.files[node.target.diff_file];
        try std.testing.expectEqualStrings(name, file.old_path.?);
        try std.testing.expectEqualStrings(name, file.new_path.?);
        if (mode_only or std.mem.eql(u8, name, "binary.dat"))
            try std.testing.expectEqual(@as(usize, 0), file.hunks.len);
        var loaded = test_support.loadedDiffOne();
        loaded.document = document;
        loaded.tree = tree;
        var page: changes_page.ChangesPageState = .{
            .load = test_support.loadState(loaded),
            .viewer = .{ .selected_node = selected_node.?, .selected_target = .{ .diff_file = node.target.diff_file } },
        };
        defer page.git_status.deinit();
        try page.git_status.replace("/repo", &status);
        acceptTestSource(&page);
        const target = testView(&page, .unstaged).stageTarget();
        try std.testing.expect(target == .ready);
        try std.testing.expectEqual(git_ops.TargetKind.file, target.ready.kind);
        try std.testing.expectEqualStrings(name, target.ready.path);
        const result = try backend.runOperation(allocator, io, .{ .context = git_context, .kind = .{ .stage_file = target.ready.path } });
        defer result.deinit(allocator);
        try std.testing.expect(result == .ok);
        const index_spec = try std.fmt.allocPrint(allocator, ":{s}", .{name});
        defer allocator.free(index_spec);
        const index_bytes = try pathTestCommand(tmp.dir, &.{ "git", "show", index_spec });
        defer allocator.free(index_bytes);
        try std.testing.expectEqualStrings(expected, index_bytes);
        if (mode_only) {
            const index_mode = try pathTestCommand(tmp.dir, &.{ "git", "ls-files", "--stage", "--", name });
            defer allocator.free(index_mode);
            try std.testing.expect(std.mem.startsWith(u8, index_mode, "100755 "));
        }
        const canary_index = try pathTestCommand(tmp.dir, &.{ "git", "show", ":choice-other.txt" });
        defer allocator.free(canary_index);
        try std.testing.expectEqualStrings("CANARY staged\n", canary_index);
        const canary_worktree = try tmp.dir.readFileAlloc(io, "choice-other.txt", allocator, .limited(1024));
        defer allocator.free(canary_worktree);
        try std.testing.expectEqualStrings("CANARY worktree\n", canary_worktree);
        const namesake_index = try pathTestCommand(tmp.dir, &.{ "git", "ls-files", "--stage", "--", "trailing.txt" });
        defer allocator.free(namesake_index);
        try std.testing.expectEqualStrings("", namesake_index);
        const namesake_worktree = try tmp.dir.readFileAlloc(io, "trailing.txt", allocator, .limited(1024));
        defer allocator.free(namesake_worktree);
        try std.testing.expectEqualStrings("UNTRACKED namesake\n", namesake_worktree);
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--", name }));
    }

    allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "mv", "rename-old.txt", "a/renamed.txt" }));
    const rename_patch = try pathTestCommand(tmp.dir, &.{ "git", "diff", "--cached", "--find-renames", "--", "rename-old.txt", "a/renamed.txt" });
    defer allocator.free(rename_patch);
    var renamed = try parser.parse(allocator, rename_patch);
    defer renamed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), renamed.files.len);
    try std.testing.expectEqual(@as(usize, 0), renamed.files[0].hunks.len);
    try std.testing.expectEqualStrings("rename-old.txt", renamed.files[0].old_path.?);
    try std.testing.expectEqualStrings("a/renamed.txt", renamed.files[0].new_path.?);
    const rename_status = try git_read.loadStatus(allocator, io, .{ .context = git_context });
    defer rename_status.deinit(allocator);
    try std.testing.expect(rename_status == .ok);
    var rename_bundle = try git_status.StatusBundle.parseOwned(allocator, rename_status.ok);
    defer rename_bundle.deinit();
    var rename_arena = std.heap.ArenaAllocator.init(allocator);
    defer rename_arena.deinit();
    const rename_tree = try file_tree.buildWithStatus(rename_arena.allocator(), renamed, rename_bundle.document);
    const renamed_node = rename_tree.nodes[rename_tree.selectedNodeIndex(0).?];
    try std.testing.expectEqualStrings("a/renamed.txt", renamed_node.path_key);
    try std.testing.expectEqual(file_tree.StagePresence.staged_only, renamed_node.stage_presence);
    var rename_rows: usize = 0;
    for (rename_tree.nodes) |node| {
        if (node.kind == .file and std.mem.eql(u8, node.path_key, "a/renamed.txt")) rename_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rename_rows);
}

test "Changes raw hunk bytes reach and leave the Git index without collateral changes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const git_command = @import("../../../git/command.zig");
    const git_read = @import("../../../git/read.zig");
    const backend = @import("../../../git/operations.zig");
    const parser = @import("../../../diff/parser.zig");
    const file_tree = @import("../../../file_tree.zig");
    const git_status = @import("../../../git/status.zig");
    const Case = struct {
        old: []const u8,
        new: []const u8,
        worktree: ?[]const u8 = null,
        textconv: bool = false,
    };
    const cases = [_]Case{
        .{ .old = "old\n", .new = "new\n" },
        .{ .old = "old\r\n", .new = "new\r\n" },
        .{ .old = "same\r\nold\n", .new = "same\r\nnew\r\n" },
        .{ .old = "old", .new = "new" },
        .{ .old = "old\r", .new = "new\r" },
        .{ .old = "old\n", .new = "new\n", .worktree = "new\r\n" },
        // The first converted patch applies successfully with the wrong bytes;
        // the second is rejected because its converted old side differs too.
        .{ .old = "BEFORE\n", .new = "after\n", .textconv = true },
        .{ .old = "before\n", .new = "after\n", .textconv = true },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "init", "--initial-branch=main" }));
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "config", "core.autocrlf", "false" }));
        try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = if (case.textconv) "a -text diff=upper\n" else if (case.worktree != null) "a text eol=crlf\n" else "a -text\n" });
        if (case.textconv)
            allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "config", "diff.upper.textconv", "tr a-z A-Z <" }));
        try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = case.old });
        try tmp.dir.writeFile(io, .{ .sub_path = "sentinel", .data = "base\n" });
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "add", "--all" }));
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }));
        try tmp.dir.writeFile(io, .{ .sub_path = "sentinel", .data = "staged sentinel\n" });
        allocator.free(try pathTestCommand(tmp.dir, &.{ "git", "add", "--", "sentinel" }));
        try tmp.dir.writeFile(io, .{ .sub_path = "sentinel", .data = "worktree sentinel\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = case.worktree orelse case.new });
        if (case.textconv) {
            const converted = try pathTestCommand(tmp.dir, &.{ "git", "diff", "--textconv", "--", "a" });
            defer allocator.free(converted);
            try std.testing.expect(std.mem.indexOf(u8, converted, "+AFTER\n") != null);
        }
        var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
        defer environment.deinit();
        const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
        const raw_diff = try git_read.loadDiff(allocator, io, .{ .context = context, .kind = .unstaged });
        defer raw_diff.deinit(allocator);
        try std.testing.expect(raw_diff == .ok);
        const raw_status = try git_read.loadStatus(allocator, io, .{ .context = context });
        defer raw_status.deinit(allocator);
        try std.testing.expect(raw_status == .ok);
        var status = try git_status.StatusBundle.parseOwned(allocator, raw_status.ok);
        defer status.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const document = try parser.parse(arena.allocator(), raw_diff.ok);
        const tree = try file_tree.buildWithStatus(arena.allocator(), document, status.document);
        var selected_node: ?usize = null;
        for (tree.nodes, 0..) |node, index| {
            if (node.kind == .file and std.mem.eql(u8, node.path_key, "a")) selected_node = index;
        }
        const target_file = tree.nodes[selected_node.?].target.diff_file;
        try std.testing.expectEqual(@as(usize, 1), document.files[target_file].hunks.len);
        var loaded = test_support.loadedDiffOne();
        loaded.document = document;
        loaded.file_text_eligibility = try @import("../../../diff/text_eligibility.zig").classifyDocument(arena.allocator(), document);
        loaded.tree = tree;
        var page: changes_page.ChangesPageState = .{
            .load = test_support.loadState(loaded),
            .viewer = .{
                .selected_node = selected_node.?,
                .selected_target = .{ .diff_file = target_file },
                .diff_cursor = .{ .hunk_header = 0 },
            },
        };
        defer page.git_status.deinit();
        defer page.staged_hunks.deinit(allocator);
        try page.git_status.replace("/repo", &status);
        acceptTestSource(&page);
        const view = testView(&page, .unstaged);
        const stage = view.selectedHunkStageTarget(allocator);
        try std.testing.expect(stage == .ready);
        defer allocator.free(stage.ready.patch);
        try std.testing.expectEqualStrings("a", stage.ready.path);

        for ([_]bool{ false, true }) |reverse| {
            const patch = if (reverse) blk: {
                try page.staged_hunks.addExact(allocator, "/repo", "a", stage.ready.session_mark_mutation.add);
                const unstage = view.selectedHunkUnstageTarget(allocator);
                try std.testing.expect(unstage == .ready);
                break :blk unstage.ready.patch;
            } else stage.ready.patch;
            defer if (reverse) allocator.free(patch);
            const result = try backend.runOperation(allocator, io, .{ .context = context, .kind = if (reverse)
                .{ .unstage_patch = .{ .patch = patch } }
            else
                .{ .stage_patch = .{ .patch = patch } } });
            defer result.deinit(allocator);
            try std.testing.expect(result == .ok);
            const index = try pathTestCommand(tmp.dir, &.{ "git", "show", ":a" });
            defer allocator.free(index);
            try std.testing.expectEqualStrings(if (reverse) case.old else case.new, index);
            const worktree = try tmp.dir.readFileAlloc(io, "a", allocator, .limited(1024));
            defer allocator.free(worktree);
            try std.testing.expectEqualStrings(case.worktree orelse case.new, worktree);
            const sentinel_index = try pathTestCommand(tmp.dir, &.{ "git", "show", ":sentinel" });
            defer allocator.free(sentinel_index);
            try std.testing.expectEqualStrings("staged sentinel\n", sentinel_index);
            const sentinel_worktree = try tmp.dir.readFileAlloc(io, "sentinel", allocator, .limited(1024));
            defer allocator.free(sentinel_worktree);
            try std.testing.expectEqualStrings("worktree sentinel\n", sentinel_worktree);
            if (case.textconv and !reverse) {
                const cached = try git_read.loadDiff(allocator, io, .{ .context = context, .kind = .{ .file = .{ .base = .cached, .path = "a" } } });
                defer cached.deinit(allocator);
                try std.testing.expect(cached == .ok);
                try std.testing.expect(std.mem.indexOf(u8, cached.ok, "+after\n") != null);
            }
        }
        if (case.textconv) {
            // Unstage restored the original index, so both readers have a real
            // target diff again. The ordinary reader is proved by the writes above.
            for ([_]git_read.GitDiffKind{
                .{ .file = .{ .base = .unstaged, .path = "a" } },
                .{ .range = "HEAD" },
            }) |kind| {
                const read = try git_read.loadDiff(allocator, io, .{ .context = context, .kind = kind });
                defer read.deinit(allocator);
                try std.testing.expect(read == .ok);
                try std.testing.expect(std.mem.indexOf(u8, read.ok, "+after\n") != null);
            }
        }
    }
}

fn pathTestCommand(cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return error.GitCommandFailed;
}

test "owned operation proposal frees every cloned field" {
    const allocator = std.testing.allocator;
    const view: View = undefined;
    var proposal = try view.ownPushProposal(allocator, .{
        .repo_epoch = 1,
        .root_identity = .{ .device = 2, .inode = 3 },
    }, .{
        .mode = .upstream,
        .repo_root = "/repo",
        .branch = "main",
        .remote = "origin",
        .remote_branch = "main",
        .oid = "abc",
        .ahead_behind = .{ .ahead = 1, .behind = 0 },
    });
    proposal.deinit(allocator);
}

test "owned operation proposal construction frees partial clones" {
    const backing = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 5) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        const view: View = undefined;
        const result = view.ownPushProposal(failing.allocator(), .{
            .repo_epoch = 1,
            .root_identity = .{ .device = 2, .inode = 3 },
        }, .{
            .mode = .upstream,
            .repo_root = "/repo",
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "abc",
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        });
        try std.testing.expectError(error.OutOfMemory, result);
    }
}

test "accepted hunk stage keeps mandatory reload when local mark allocation fails" {
    const backing = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var page: changes_page.ChangesPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        };
        defer page.deinit(backing);
        acceptTestSource(&page);
        const view = testView(&page, .unstaged);
        const key = view.sessionHunkMarkKey(2) orelse return error.ExpectedSessionHunkMarkKey;
        const controller: Controller = .{
            .page = &page,
            .navigation = undefined,
            .view_state = view,
        };
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });

        const applied = controller.applyAcceptedOutcome(failing.allocator(), .{ .stage_hunk = .{
            .repo_root = "/repo",
            .path = "src/main.zig",
            .hunk_index = 2,
            .session_mark_mutation = .{ .add = key },
        } }, true);

        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(LocalEffectFailure.staged_hunk_mark_record, applied.local_effect_failure.?);
        try std.testing.expectEqualStrings("/repo", applied.reload.status);
        try std.testing.expectEqual(@as(usize, 0), page.staged_hunks.items.items.len);
    }
}

test "accepted hunk add is ignored after its captured content lineage is invalidated" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    const view = testView(&page, .unstaged);
    const key = view.sessionHunkMarkKey(0) orelse return error.ExpectedSessionHunkMarkKey;
    const controller: Controller = .{
        .page = &page,
        .navigation = undefined,
        .view_state = view,
    };

    page.source_session_revision +%= 1;
    const applied = controller.applyAcceptedOutcome(allocator, .{ .stage_hunk = .{
        .repo_root = "/repo",
        .path = "a",
        .hunk_index = 0,
        .session_mark_mutation = .{ .add = key },
    } }, true);

    try std.testing.expect(applied.local_effect_failure == null);
    try std.testing.expectEqualStrings("/repo", applied.reload.status);
    try std.testing.expectEqual(@as(usize, 0), page.staged_hunks.items.items.len);
}

test "accepted hunk remove consumes only its exact captured key after lineage invalidation" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    const view = testView(&page, .unstaged);
    const key = view.sessionHunkMarkKey(0) orelse return error.ExpectedSessionHunkMarkKey;
    try page.staged_hunks.addExact(allocator, "/repo", "a", key);
    const controller: Controller = .{
        .page = &page,
        .navigation = undefined,
        .view_state = view,
    };

    page.source_session_revision +%= 1;
    const applied = controller.applyAcceptedOutcome(allocator, .{ .unstage_hunk = .{
        .repo_root = "/repo",
        .path = "a",
        .hunk_index = 0,
        .session_mark_mutation = .{ .remove = key },
        .reload_after_success = false,
    } }, true);

    try std.testing.expectEqualStrings("/repo", applied.reload.status);
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", key));
}

fn testView(page: *const changes_page.ChangesPageState, source: diff_source.SourceMode) View {
    return .{
        .page = page,
        .navigation = .{
            .page = page,
            .repo_root = "/repo",
            .source = source,
            .layout = .{ .width = 100, .height = 40 },
        },
        .source = source,
        .repo_root = "/repo",
        .activation_state = .{ .active = .{
            .activation_id = 1,
            .repo_epoch = 0,
            .members = .{
                .source = if (page.auto_reload.sourceIsActionable()) .fresh else .unavailable,
                .status = authority.auxiliaryMember(page.status_load),
                .branch = authority.auxiliaryMember(page.branch_status_load),
            },
        } },
    };
}

fn acceptTestSource(page: *changes_page.ChangesPageState) void {
    page.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test"));
}

test "mutation fence makes retained Changes operation targets inert" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    var status = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status);
    var branch_builder = @import("../../../git/branch_status.zig").Builder.init(allocator);
    errdefer branch_builder.deinit();
    try branch_builder.setOid("abc123");
    try branch_builder.setBranchHead("main");
    try branch_builder.setUpstream("origin/main");
    branch_builder.setAheadBehind(1, 0);
    var branch = branch_builder.finish();
    defer branch.deinit();
    try page.branch_status.replace("/repo", &branch);
    const view = testView(&page, .unstaged);

    try std.testing.expect(view.activation().satisfiesAction(.stage_hunk));
    switch (view.stageTarget()) {
        .ready => {},
        else => return error.ExpectedReadyStageTarget,
    }
    switch (view.unstageTarget()) {
        .ready => {},
        else => return error.ExpectedReadyUnstageTarget,
    }
    switch (view.commitSummary()) {
        .ready => |summary| try std.testing.expectEqual(@as(usize, 1), summary.count),
        else => return error.ExpectedReadyCommitSummary,
    }
    const hunk_target = switch (view.selectedHunkStageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedReadyHunkStageTarget,
    };
    defer allocator.free(hunk_target.patch);
    switch (view.pushTarget()) {
        .ready => {},
        else => return error.ExpectedReadyPushTarget,
    }
    try std.testing.expect(view.pullTarget() == .dirty_worktree);
    switch (view.fetchTarget()) {
        .ready => {},
        else => return error.ExpectedReadyFetchTarget,
    }

    const owner: app_actions.PendingAction = .{
        .generation = 41,
        .kind = .stage_hunk,
    };
    try std.testing.expect(page.repository_read_authority.closeForMutation(owner));
    try std.testing.expect(view.activation() == .inactive);
    const members = view.activationMembers();
    try std.testing.expectEqual(authority.MemberFreshness.unavailable, members.source);
    try std.testing.expectEqual(authority.MemberFreshness.unavailable, members.status);
    try std.testing.expectEqual(authority.MemberFreshness.unavailable, members.branch);

    try std.testing.expect(view.stageTarget() == .stale_source);
    try std.testing.expect(view.toggleStageTarget() == .stale_source);
    try std.testing.expect(view.unstageTarget() == .stale_source);
    try std.testing.expect(view.discardTarget() == .stale_source);
    try std.testing.expect(view.commitSummary() == .loading_or_stale);
    try std.testing.expect(view.selectedHunkToggleOperation() == .stale_source);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .stale_source);
    try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .stale_source);
    try std.testing.expect(view.pushTarget() == .loading_branch_status);
    try std.testing.expect(view.pullTarget() == .loading_branch_status);
    try std.testing.expect(view.fetchTarget() == .loading_branch_status);

    try std.testing.expect(page.repository_read_authority.reopenForMutation(owner));
    try std.testing.expect(view.activation().satisfiesAction(.stage_hunk));
    switch (view.stageTarget()) {
        .ready => {},
        else => return error.ExpectedRestoredStageTarget,
    }
    switch (view.pushTarget()) {
        .ready => {},
        else => return error.ExpectedRestoredPushTarget,
    }
    try std.testing.expect(view.pullTarget() == .dirty_worktree);
    switch (view.fetchTarget()) {
        .ready => {},
        else => return error.ExpectedRestoredFetchTarget,
    }
}

test "pull remains gated by pending and stale file status" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{};
    defer page.deinit(allocator);
    var builder = @import("../../../git/branch_status.zig").Builder.init(allocator);
    errdefer builder.deinit();
    try builder.setOid("abc123");
    try builder.setBranchHead("main");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(0, 1);
    var branch = builder.finish();
    defer branch.deinit();
    try page.branch_status.replace("/repo", &branch);

    page.status_load.pending = .{ .generation = 1 };
    try std.testing.expect(testView(&page, .unstaged).pullTarget() == .status_loading);
    page.status_load.pending = null;
    page.status_load.freshness = .stale_refresh;
    try std.testing.expect(testView(&page, .unstaged).pullTarget() == .status_stale);
}

test "stage target skips only fresh staged-only files" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.git_status.deinit();
    acceptTestSource(&page);

    var staged = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try page.git_status.replace("/repo", &staged);
    switch (testView(&page, .unstaged).stageTarget()) {
        .already_staged => |path| try std.testing.expectEqualStrings("src/added.zig", path),
        else => return error.ExpectedAlreadyStagedTarget,
    }

    var mixed = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "AM src/added.zig\x00");
    try page.git_status.replace("/repo", &mixed);
    switch (testView(&page, .unstaged).stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src/added.zig", target.path);
        },
        else => return error.ExpectedMixedStageTarget,
    }

    var conflict = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "UU src/added.zig\x00");
    try page.git_status.replace("/repo", &conflict);
    try std.testing.expect(testView(&page, .unstaged).stageTarget() == .ready);

    page.status_load.pending = .{ .generation = 1 };
    try std.testing.expect(testView(&page, .unstaged).stageTarget() == .ready);
    page.status_load.pending = null;

    var other = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try page.git_status.replace("/other", &other);
    try std.testing.expect(testView(&page, .unstaged).stageTarget() == .ready);
    try std.testing.expect(testView(&page, .{ .patch_file = "change.patch" }).stageTarget() == .unavailable_source);
}

test "retained staged-only read epoch authority builds unstage patch and becomes inert when superseded" {
    const allocator = std.testing.allocator;
    const cached_patch =
        \\diff --git a/a b/a
        \\index 1111111..2222222 100644
        \\--- a/a
        \\+++ b/a
        \\@@ -1,4 +1,4 @@ first
        \\ one
        \\ two
        \\-old
        \\+new
        \\ four
        \\@@ -20,2 +20,2 @@ second
        \\ late one
        \\-late old
        \\+late new
        \\
    ;
    var component = try projection_component.ParsedComponent.parse(allocator, cached_patch);
    const owner = component.arena.?.allocator();
    const stage_states = try owner.alloc(diff_hunk_projection.HunkStageState, 2);
    @memset(stage_states, .staged);
    const action_origins = try owner.alloc(diff_hunk_projection.HunkActionOrigin, 2);
    action_origins[0] = .{ .cached = 0 };
    action_origins[1] = .{ .cached = 1 };

    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    _ = page.activation.activate(0, .pending, .pending, .pending);
    acceptTestSource(&page);
    var status = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &status);
    page.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            page.source_session_revision,
            page.status_snapshot_revision,
        ),
        .value = .{ .primary_staged_only_authority = .{
            .projection = .{
                .hunk_stage_states = stage_states,
                .hunk_action_origins = action_origins,
            },
            .cached_component = component,
            .status_snapshot_revision = page.status_snapshot_revision,
        } },
    });
    component.arena = null;

    const view = testView(&page, .unstaged);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .already_staged_hunk);
    const target = switch (view.selectedHunkUnstageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedStagedOnlyUnstageTarget,
    };
    defer allocator.free(target.patch);
    try std.testing.expectEqualStrings("a", target.path);
    try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
    try std.testing.expectEqual(git_ops.SessionHunkMarkMutation.none, target.session_mark_mutation);
    try std.testing.expect(std.mem.indexOf(u8, target.patch, "@@ -1,4 +1,4 @@ first") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.patch, "+new") != null);

    const mark_key = view.sessionHunkMarkKey(0) orelse return error.ExpectedSessionHunkMarkKey;
    const other_hunk_key: git_ops.SessionHunkMarkKey = .{
        .content = mark_key.content,
        .display_hunk_index = 1,
    };
    try page.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    try page.staged_hunks.addExact(allocator, "/repo", "a", other_hunk_key);
    try page.staged_hunks.addExact(allocator, "/repo", "other.zig", mark_key);

    const local_target = switch (view.selectedHunkUnstageTarget(allocator)) {
        .ready => |ready| ready,
        else => return error.ExpectedSessionMarkedUnstageTarget,
    };
    defer allocator.free(local_target.patch);
    try std.testing.expect(local_target.session_mark_mutation == .remove);
    try std.testing.expect(local_target.session_mark_mutation.remove.eql(mark_key));

    const controller: Controller = .{
        .page = &page,
        .navigation = undefined,
        .view_state = view,
    };
    _ = controller.applyAcceptedOutcome(allocator, .{ .unstage_hunk = .{
        .repo_root = local_target.repo_root,
        .path = local_target.path,
        .hunk_index = local_target.hunk_index,
        .session_mark_mutation = local_target.session_mark_mutation,
        .reload_after_success = local_target.reload_after_success,
    } }, true);
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expect(page.staged_hunks.containsExact("/repo", "a", other_hunk_key));
    try std.testing.expect(page.staged_hunks.containsExact("/repo", "other.zig", mark_key));

    const displayed_request = page.changes_projection.displayed.request().?;
    page.repository_read_authority.epoch = .{ .value = 2 };
    try std.testing.expect(view.navigation.displayedProjectionRequestIsActive(displayed_request.*));
    try std.testing.expect(view.selectedHunkToggleOperation() == .stale_status);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .stale_status);
    try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .stale_status);

    page.repository_read_authority.epoch = displayed_request.read_epoch;
    page.repository_read_authority.phase = .{ .mutation_in_flight = .{
        .generation = 23,
        .kind = .unstage_hunk,
    } };
    try std.testing.expect(!view.displayedProjectionReadIsFresh());
    try std.testing.expect(view.selectedHunkToggleOperation() == .stale_status);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .stale_status);
    try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .stale_status);
}

test "cached projection hunk unstage keeps source and status reload membership" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    var status = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &status);
    page.status_load.markSuccess();

    page.viewer.selected_target = .{ .status_only = 0 };
    page.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            app_page.RequestIdentity.changes(0, 1),
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            0,
            0,
        ),
        .value = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, test_support.diff_one) },
    });
    const view = testView(&page, .unstaged);
    const target = switch (view.selectedHunkUnstageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedCachedProjectionUnstageTarget,
    };
    defer allocator.free(target.patch);
    try std.testing.expectEqual(git_ops.SessionHunkMarkMutation.none, target.session_mark_mutation);
    try std.testing.expect(target.reload_after_success);

    const controller: Controller = .{
        .page = &page,
        .navigation = undefined,
        .view_state = undefined,
    };
    const applied = controller.applyAcceptedOutcome(allocator, .{ .unstage_hunk = .{
        .repo_root = target.repo_root,
        .path = target.path,
        .hunk_index = target.hunk_index,
        .session_mark_mutation = target.session_mark_mutation,
        .reload_after_success = target.reload_after_success,
    } }, true);
    try std.testing.expect(applied.reload == .source_and_aux);
}

test "stage toggle resolves file operation from fresh status" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.git_status.deinit();
    acceptTestSource(&page);

    var mixed = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "AM src/added.zig\x00");
    try page.git_status.replace("/repo", &mixed);
    try std.testing.expectEqual(git_ops.ToggleStageTargetResult{ .operation = .stage }, testView(&page, .unstaged).toggleStageTarget());

    var staged = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try page.git_status.replace("/repo", &staged);
    try std.testing.expectEqual(git_ops.ToggleStageTargetResult{ .operation = .unstage }, testView(&page, .unstaged).toggleStageTarget());
    page.status_load.pending = .{ .generation = 1 };
    try std.testing.expect(testView(&page, .unstaged).toggleStageTarget() == .stale_status);
    page.status_load.pending = null;
    var conflict = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "UU src/added.zig\x00");
    try page.git_status.replace("/repo", &conflict);
    switch (testView(&page, .unstaged).toggleStageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqual(git_ops.TargetKind.file, target.kind);
            try std.testing.expectEqualStrings("src/added.zig", target.path);
        },
        else => return error.ExpectedToggleConflict,
    }
    try std.testing.expect(testView(&page, .{ .range = "main...HEAD" }).toggleStageTarget() == .unavailable_source);
}

test "changes root expansion retains whole-repository stage authority" {
    const loaded = test_support.loadedDiffRootedNested();
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(loaded),
        .viewer = .{
            .selected_target = .{ .diff_file = 1 },
            .selected_node = 0,
        },
    };
    defer page.git_status.deinit();
    acceptTestSource(&page);

    const target = testView(&page, .unstaged).selectedSidebarActionTarget() orelse
        return error.ExpectedRepositoryActionTarget;
    try std.testing.expectEqual(git_ops.TargetKind.repository, target.kind);
    try std.testing.expectEqualStrings("", target.path);
    try std.testing.expect(page.load.state.loaded.loaded.visibleNodeCount() > 1);
    try std.testing.expect(page.load.state.loaded.loaded.tree.nodes[0].kind == .repo_root);

    var unstaged = try @import("../../../git/status.zig").StatusBundle.parseOwned(
        std.testing.allocator,
        " M src/a\x00",
    );
    try page.git_status.replace("/repo", &unstaged);
    try std.testing.expectEqual(
        git_ops.ToggleStageTargetResult{ .operation = .stage },
        testView(&page, .unstaged).toggleStageTarget(),
    );

    var staged = try @import("../../../git/status.zig").StatusBundle.parseOwned(
        std.testing.allocator,
        "A  src/a\x00",
    );
    try page.git_status.replace("/repo", &staged);
    try std.testing.expectEqual(
        git_ops.ToggleStageTargetResult{ .operation = .unstage },
        testView(&page, .unstaged).toggleStageTarget(),
    );
}

test "unstage target requires fresh staged status" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.git_status.deinit();
    acceptTestSource(&page);
    var staged = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try page.git_status.replace("/repo", &staged);
    try std.testing.expect(testView(&page, .unstaged).unstageTarget() == .ready);
    page.status_load.pending = .{ .generation = 1 };
    try std.testing.expect(testView(&page, .unstaged).unstageTarget() == .stale_status);
    page.status_load.pending = null;

    var other = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "A  src/added.zig\x00");
    try page.git_status.replace("/other", &other);
    try std.testing.expect(testView(&page, .unstaged).unstageTarget() == .stale_status);

    var unstaged = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, " M src/added.zig\x00");
    try page.git_status.replace("/repo", &unstaged);
    try std.testing.expect(testView(&page, .unstaged).unstageTarget() == .no_staged_content);
    var conflict = try @import("../../../git/status.zig").StatusBundle.parseOwned(std.testing.allocator, "UU src/added.zig\x00");
    try page.git_status.replace("/repo", &conflict);
    try std.testing.expect(testView(&page, .unstaged).unstageTarget() == .conflict_unsupported);
    try std.testing.expect(testView(&page, .{ .range = "main...HEAD" }).unstageTarget() == .unavailable_source);
}

test "hunk toggle resolves source and session staged state" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    var status = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &status);
    const view = testView(&page, .unstaged);
    const key = view.sessionHunkMarkKey(0) orelse return error.ExpectedSessionHunkMarkKey;
    try std.testing.expectEqual(git_ops.ToggleHunkTargetResult{ .operation = .stage }, view.selectedHunkToggleOperation());
    const stage_target = switch (view.selectedHunkStageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedReadyHunkStageTarget,
    };
    defer allocator.free(stage_target.patch);
    try std.testing.expect(stage_target.session_mark_mutation == .add);
    try std.testing.expect(stage_target.session_mark_mutation.add.eql(key));

    try page.staged_hunks.addExact(allocator, "/repo", "a", key);
    try std.testing.expectEqual(git_ops.ToggleHunkTargetResult{ .operation = .unstage }, view.selectedHunkToggleOperation());
    const unstage_target = switch (view.selectedHunkUnstageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedReadyHunkUnstageTarget,
    };
    defer allocator.free(unstage_target.patch);
    try std.testing.expect(unstage_target.session_mark_mutation == .remove);
    try std.testing.expect(unstage_target.session_mark_mutation.remove.eql(key));

    try std.testing.expect(testView(&page, .{ .range = "main...HEAD" }).selectedHunkToggleOperation() == .unavailable_source);
}

test "inert cached projection blocks hunk authority without changing file authority" {
    const allocator = std.testing.allocator;
    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";
    var cached = try app_load.buildLoadedBundle(allocator, invalid_patch);
    var cached_owned = true;
    defer if (cached_owned) cached.deinit();

    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    var staged = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged);
    page.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            app_page.RequestIdentity.changes(0, 1),
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            0,
            0,
        ),
        .value = .{ .cached_diff = cached },
    });
    cached_owned = false;

    const view = testView(&page, .unstaged);
    try std.testing.expect(view.selectedHunkToggleOperation() == .inert_invalid_utf8);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .inert_invalid_utf8);
    try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .inert_invalid_utf8);
    try std.testing.expectEqualStrings(
        "hunk actions unavailable for non-UTF-8 diff text",
        git_ops.inert_hunk_action_message,
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, git_ops.inert_hunk_action_message, 0xff) == null);
    try std.testing.expect(view.unstageTarget() == .ready);
}

test "inert boundary retained preview never yields a hunk write" {
    const allocator = std.testing.allocator;
    var cached = try app_load.buildLoadedBundle(allocator, test_support.diff_one);
    var cached_owned = true;
    defer if (cached_owned) cached.deinit();

    var page: changes_page.ChangesPageState = .{
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        },
    };
    defer page.deinit(allocator);
    acceptTestSource(&page);
    // The boundary already advanced status past the preview owner: the entry
    // is unstaged-only and the retained request is one revision behind.
    var unstaged = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged);
    page.changes_projection.installReady(.{
        .request = try changes_projection.testing.cloneRequest(
            allocator,
            app_page.RequestIdentity.changes(0, 1),
            1,
            "/repo",
            "a",
            .cached_diff,
            .unstaged,
            0,
            page.status_snapshot_revision,
        ),
        .value = .{ .cached_diff = cached },
    });
    cached_owned = false;
    page.status_snapshot_revision += 1;

    // The stale revision disqualifies the cached projection as hunk
    // authority (`selectedHunkUsesCachedProjection` requires the current
    // status snapshot revision) and the status-only row offers no source
    // file, so every hunk write resolves to `.no_file` without producing a
    // patch.
    const view = testView(&page, .unstaged);
    try std.testing.expect(view.selectedHunkToggleOperation() == .no_file);
    try std.testing.expect(view.selectedHunkStageTarget(allocator) == .no_file);
    try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .no_file);
}

test "either inert combined component blocks all hunk targets without primary fallback" {
    const allocator = std.testing.allocator;
    const valid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+valid\n";
    const invalid_patch =
        "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";

    for ([_]bool{ true, false }) |cached_is_invalid| {
        var cached = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) invalid_patch else valid_patch);
        var cached_owned = true;
        defer if (cached_owned) cached.deinit();
        var unstaged = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) valid_patch else invalid_patch);
        var unstaged_owned = true;
        defer if (unstaged_owned) unstaged.deinit();

        var page: changes_page.ChangesPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
            },
        };
        defer page.deinit(allocator);
        acceptTestSource(&page);
        var status = try @import("../../../git/status.zig").StatusBundle.parseOwned(allocator, "MM a\x00");
        try page.git_status.replace("/repo", &status);
        page.changes_projection.installReady(.{
            .request = try changes_projection.testing.cloneRequest(
                allocator,
                app_page.RequestIdentity.changes(0, 1),
                1,
                "/repo",
                "a",
                .combined_hunks,
                .unstaged,
                0,
                0,
            ),
            .value = .{ .inert_combined = .{
                .cached_bundle = cached,
                .unstaged_bundle = unstaged,
            } },
        });
        cached_owned = false;
        unstaged_owned = false;

        const view = testView(&page, .unstaged);
        try std.testing.expect(view.selectedHunkToggleOperation() == .inert_invalid_utf8);
        try std.testing.expect(view.selectedHunkStageTarget(allocator) == .inert_invalid_utf8);
        try std.testing.expect(view.selectedHunkUnstageTarget(allocator) == .inert_invalid_utf8);
        try std.testing.expect(view.unstageTarget() == .ready);
    }
}
