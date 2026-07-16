//! Review-local reload, projection identity, and navigation-restore ownership.
//!
//! Async task allocation/spawn remains a shell effect during Phase 9 A3. This
//! module owns the page state transitions which prepare and reconcile those
//! effects; it deliberately has no `App`, `Ctx`, overlay, or process access.

const std = @import("std");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const builtin = @import("builtin");
const auto_reload = @import("../../auto_reload.zig");
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const load_state = @import("../../load_state.zig");
const review_projection = @import("../../review_projection.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");
const review_page = @import("../review.zig");
const review_selection = @import("selection.zig");
const authority = @import("authority.zig");
const navigation = @import("navigation.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_source = @import("../../../diff/source.zig");
const file_tree = @import("../../../file_tree.zig");
const git_backend = @import("../../../git/backend.zig");
const git_status = @import("../../../git/status.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

pub const Diagnostic = union(enum) {
    status_load_failed: []const u8,
    branch_status_load_failed: []const u8,
    branch_status_parse_failed,
};

pub const CompletionApply = struct {
    project_status: ?bool = null,
    diagnostic: ?Diagnostic = null,
    skip_redraw: bool = false,
};

/// Owned cross-boundary command produced only after Review has accepted the
/// discovery task identity. App consumes the discovery to commit active-repo
/// identity; Review never mutates shell repository state directly.
pub const DiscoveryApply = struct {
    commit_discovery: ?repo_discovery.DiscoveryResult = null,

    pub fn deinit(self: *DiscoveryApply, allocator: std.mem.Allocator) void {
        if (self.commit_discovery) |*discovery| discovery.deinit(allocator);
        self.commit_discovery = null;
    }

    pub fn takeCommitDiscovery(self: *DiscoveryApply) ?repo_discovery.DiscoveryResult {
        const discovery = self.commit_discovery;
        self.commit_discovery = null;
        return discovery;
    }
};

pub const DiscoveryCommitOutcome = enum {
    none,
    start_initial_read,
};

pub const ProjectionApply = struct {
    result_transferred: bool = false,
};

pub const RedrawDisposition = enum {
    normal,
    skip,
    skip_unless_recovered_failure_cleared,
};

pub const SourceApply = struct {
    result_transferred: bool = false,
    recovered_failure: ?auto_reload.FailureIdentity = null,
    auto_reload_failure: ?struct {
        identity: auto_reload.FailureIdentity,
        message: []const u8,
    } = null,
    redraw: RedrawDisposition = .normal,
};

pub const DeferredSourceApplyOutcome = struct {
    source: SourceApply,
    owned_failure_message: ?[]u8 = null,

    pub fn deinit(self: *DeferredSourceApplyOutcome, allocator: std.mem.Allocator) void {
        if (self.owned_failure_message) |message| allocator.free(message);
        self.* = undefined;
    }
};

pub const ProjectionTarget = struct {
    repo_root: []const u8,
    path_key: []const u8,
    kind: review_projection.Kind,
    source_kind: review_projection.SourceKind,
};

pub const SourceLoadOptions = struct {
    clear_visible_state: bool,
    kind: review_page.ReloadKind,
    background_cycle_id: ?u64 = null,
};

pub const OwnedRepoDiscoveryRead = struct {
    identity: app_page.RequestIdentity,
    generation: u64,
    background_cycle_id: ?u64,

    fn deinit(self: *OwnedRepoDiscoveryRead, _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

pub const OwnedSourceRead = struct {
    identity: app_page.RequestIdentity,
    request: diff_source.LoadRequest,
    generation: u64,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    background_cycle_id: ?u64,

    fn deinit(self: *OwnedSourceRead, allocator: std.mem.Allocator) void {
        diff_source.freeLoadRequest(allocator, self.request);
        self.* = undefined;
    }
};

pub const OwnedStatusRead = struct {
    identity: app_page.RequestIdentity,
    repo_root: []u8,
    generation: u64,
    origin: git_backend.ReadOrigin,
    background_cycle_id: ?u64,

    fn deinit(self: *OwnedStatusRead, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.* = undefined;
    }
};

pub const OwnedBranchStatusRead = struct {
    identity: app_page.RequestIdentity,
    repo_root: []u8,
    generation: u64,
    background_cycle_id: ?u64,

    fn deinit(self: *OwnedBranchStatusRead, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.* = undefined;
    }
};

/// One owned Review read effect transferred to the shell. The page keeps a
/// separately cloned pending identity; the command alone owns the request that
/// crosses into the async task.
pub const OwnedReadCommand = union(enum) {
    repo_discovery: OwnedRepoDiscoveryRead,
    source_load: OwnedSourceRead,
    status_load: OwnedStatusRead,
    branch_status_load: OwnedBranchStatusRead,
    review_projection: review_projection.Request,

    pub fn deinit(self: *OwnedReadCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .repo_discovery => |*request| request.deinit(allocator),
            .source_load => |*request| request.deinit(allocator),
            .status_load => |*request| request.deinit(allocator),
            .branch_status_load => |*request| request.deinit(allocator),
            .review_projection => |*request| request.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ReviewUpdate = struct {
    command: ?OwnedReadCommand = null,

    pub fn deinit(self: *ReviewUpdate, allocator: std.mem.Allocator) void {
        if (self.command) |*command| command.deinit(allocator);
        self.command = null;
    }

    pub fn takeCommand(self: *ReviewUpdate) ?OwnedReadCommand {
        const command = self.command;
        self.command = null;
        return command;
    }
};

pub const View = struct {
    page: *const review_page.ReviewPageState,
    navigation: navigation.View,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,

    pub fn captureAnchor(self: View, allocator: std.mem.Allocator) !?review_page.ReloadAnchor {
        const loaded = self.navigation.activeLoadedDiffConst() orelse return null;
        const path_key = self.navigation.selectedStagePathKey() orelse return null;
        const selected_target = self.page.viewer.selected_target orelse return null;
        const visible_row = loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0;

        return .{
            .path_key = try allocator.dupe(u8, path_key),
            .selected_target_tag = std.meta.activeTag(selected_target),
            .visible_sidebar_row = visible_row,
            .diff_cursor = self.page.viewer.diff_cursor,
            .diff_cursor_offset = self.navigation.selectedDiffCursorOffset(),
            .diff_scroll = self.page.viewer.diff_scroll,
            .diff_horizontal_scroll = self.page.viewer.diff_horizontal_scroll,
            .sidebar_horizontal_scroll = self.page.viewer.sidebar_horizontal_scroll,
            .search_coordinate = if (self.page.search.match) |match| match.coordinate else null,
        };
    }

    pub fn captureDisplayRestore(self: View, allocator: std.mem.Allocator) !?review_page.PendingDisplayNavigationRestore {
        const repo_root = self.repo_root orelse return null;
        var anchor = try self.captureAnchor(allocator) orelse return null;
        errdefer anchor.deinit(allocator);
        return .{
            .repo_root = try allocator.dupe(u8, repo_root),
            .source_kind = sourceKind(self.source),
            .source_session_revision = self.page.source_session_revision,
            .original = anchor,
            .captured_input_revision = self.page.display_navigation_input_revision,
        };
    }

    pub fn projectionTarget(self: View) ?ProjectionTarget {
        const repo_root = self.repo_root orelse return null;
        const projection_source = sourceKind(self.source);

        if (self.navigation.selectedFile()) |file| {
            const path_key = diff_file.canonicalPathKey(file) orelse return null;
            const entry = self.navigation.freshStatusEntryForPathKey(repo_root, path_key) orelse return null;
            if (sourceIsUnstaged(self.source) and isCombinedHunkProjectionCandidate(file, entry)) {
                return .{
                    .repo_root = repo_root,
                    .path_key = path_key,
                    .kind = .combined_hunks,
                    .source_kind = projection_source,
                };
            }
        }

        const entry = self.navigation.selectedStatusEntry() orelse return null;
        const path_key = entry.canonicalPathKey() orelse return null;
        return switch (file_tree.stagePresenceFromEntry(entry)) {
            .staged_only, .mixed => .{
                .repo_root = repo_root,
                .path_key = path_key,
                .kind = .cached_diff,
                .source_kind = projection_source,
            },
            .untracked => .{
                .repo_root = repo_root,
                .path_key = path_key,
                .kind = .generated_added_file,
                .source_kind = projection_source,
            },
            else => null,
        };
    }

    pub fn displayedMatchesStableIdentity(self: View, target: ProjectionTarget) bool {
        const request = self.page.review_projection.displayed.request() orelse return false;
        return request.matchesDisplayIdentity(
            target.repo_root,
            target.path_key,
            target.source_kind,
            self.page.source_session_revision,
        );
    }

    pub fn canRetainDisplayedProjection(self: View) bool {
        const request = self.page.review_projection.displayed.request() orelse return false;
        const repo_root = self.repo_root orelse return false;
        const path_key = self.navigation.selectedStagePathKey() orelse return false;
        return request.matchesDisplayIdentity(
            repo_root,
            path_key,
            sourceKind(self.source),
            self.page.source_session_revision,
        ) and !self.page.status_load.isFresh();
    }

    pub fn pendingDisplayRestoreMatchesTarget(self: View, target: ProjectionTarget) bool {
        const restore = self.page.pending_display_navigation_restore orelse return false;
        return restore.source_session_revision == self.page.source_session_revision and
            restore.source_kind == target.source_kind and
            std.mem.eql(u8, restore.repo_root, target.repo_root) and
            std.mem.eql(u8, restore.authoritative().path_key, target.path_key);
    }
};

pub const Controller = struct {
    page: *review_page.ReviewPageState,
    navigation: navigation.Controller,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,

    fn acceptsIdentity(self: Controller, identity: app_page.RequestIdentity) bool {
        return self.page.activation.acceptsRepoEpoch(identity, self.repo_epoch);
    }

    /// The live drag is the only state which borrows displayed source or
    /// projection storage. Completed selections are fully owned and therefore
    /// never participate in this reload gate.
    fn displayMutationBlockedByDrag(self: Controller) bool {
        return self.page.selection_owner.activeMouseSelection();
    }

    fn clearCompletedSelection(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page.completed_selection) |*selection| selection.deinit(allocator);
        self.page.completed_selection = null;
    }

    fn clearProjectionCompletedSelection(self: Controller, allocator: std.mem.Allocator) void {
        const completed = self.page.completed_selection orelse return;
        switch (completed.token.display) {
            .loaded => {},
            .cached_projection, .combined_projection, .generated_untracked => self.clearCompletedSelection(allocator),
        }
    }

    fn contentTokenForReady(self: Controller, ready: *const review_projection.Ready) ?review_selection.ReviewContentToken {
        const display: review_selection.DisplayBasis = switch (ready.*) {
            .cached_diff => |bundle| .{ .cached_projection = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .cached = bundle.fingerprint,
            } },
            .combined_hunks => |bundle| .{ .combined_projection = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .cached = bundle.cached_bundle.fingerprint,
                .unstaged = bundle.unstaged_bundle.fingerprint,
            } },
            .generated_added_file => |bundle| .{ .generated_untracked = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .source = bundle.fingerprint(),
            } },
            .inert_combined, .status_body => return null,
        };
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = review_selection.SourceBasis.init(self.source),
            .source_session_revision = self.page.source_session_revision,
            .display = display,
        };
    }

    /// A candidate is meaningful only for the exact semantic display basis it
    /// captured. Delivery IDs and cache slots are intentionally absent, so an
    /// exact rebuild survives while changed content is cleared before the old
    /// displayed owner can be moved or freed.
    fn reconcileCompletedSelectionForReady(
        self: Controller,
        allocator: std.mem.Allocator,
        ready: *const review_projection.Ready,
    ) void {
        const completed = self.page.completed_selection orelse return;
        const incoming = self.contentTokenForReady(ready) orelse {
            self.clearCompletedSelection(allocator);
            return;
        };
        if (!completed.token.eql(incoming)) self.clearCompletedSelection(allocator);
    }

    /// A normal loaded diff intentionally has no projection target. Reaching
    /// that steady state must not erase an owned candidate captured from the
    /// same loaded bytes; projection-derived candidates still become stale
    /// when their displayed projection disappears.
    fn reconcileCompletedSelectionForNoProjectionTarget(
        self: Controller,
        allocator: std.mem.Allocator,
    ) void {
        const completed = self.page.completed_selection orelse return;
        const primary = switch (self.navigation.view().displayedReviewBody()) {
            .primary => |primary| primary,
            else => {
                self.clearCompletedSelection(allocator);
                return;
            },
        };
        const current = review_selection.ReviewContentToken{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = review_selection.SourceBasis.init(self.source),
            .source_session_revision = self.page.source_session_revision,
            .display = .{ .loaded = .init(primary.loaded.text) },
        };
        if (!completed.token.eql(current)) self.clearCompletedSelection(allocator);
    }

    pub fn failActiveMember(self: Controller, member: authority.Member) void {
        const identity = self.page.activation.currentIdentity() orelse return;
        _ = self.page.activation.finishMember(identity, member, .failed);
    }

    pub fn view(self: Controller) View {
        return .{
            .page = self.page,
            .navigation = self.navigation.view(),
            .source = self.source,
            .repo_root = self.repo_root,
        };
    }

    pub fn invalidateStatusSnapshot(self: Controller) void {
        _ = self.page.status_load.prepare(true);
        self.page.pending_initial_first_visible_selection = false;
    }

    pub fn dropStatusSnapshot(self: Controller, allocator: ?std.mem.Allocator) void {
        _ = self.page.status_load.prepare(false);
        self.page.pending_initial_first_visible_selection = false;
        if (self.page.git_status.repo_root != null or self.page.git_status.document.entries.len != 0) {
            self.advanceStatusSnapshotRevision(allocator);
        }
        self.page.git_status.clear();
    }

    pub fn invalidateBranchStatusSnapshot(self: Controller) void {
        _ = self.page.branch_status_load.prepare(false);
        self.page.branch_status.clear();
    }

    pub fn beginPendingReload(self: Controller, allocator: std.mem.Allocator, generation: u64, kind: review_page.ReloadKind) !void {
        self.clearPendingReload(allocator);
        const anchor = switch (kind) {
            .manual, .watch => try self.view().captureAnchor(allocator),
            .initial, .action_result, .repo_switch => null,
        };
        errdefer if (anchor) |*captured| captured.deinit(allocator);
        self.page.pending_reload = .{ .generation = generation, .kind = kind, .anchor = anchor };
    }

    pub fn takePendingReloadIfGeneration(self: Controller, generation: u64) ?review_page.PendingReload {
        const pending_generation = if (self.page.pending_reload) |pending| pending.generation else null;
        return switch (load_state.pendingReloadConsumption(pending_generation, generation)) {
            .consume_generation_match => blk: {
                const pending = self.page.pending_reload.?;
                self.page.pending_reload = null;
                break :blk pending;
            },
            .no_pending_reload, .preserve_generation_mismatch => null,
        };
    }

    pub fn clearPendingReloadIfGeneration(self: Controller, allocator: std.mem.Allocator, generation: u64) void {
        var pending = self.takePendingReloadIfGeneration(generation) orelse return;
        pending.deinit(allocator);
    }

    pub fn clearPendingReload(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page.pending_reload) |*pending| pending.deinit(allocator);
        self.page.pending_reload = null;
    }

    pub fn installDisplayRestore(self: Controller, allocator: std.mem.Allocator, restore: review_page.PendingDisplayNavigationRestore) void {
        self.clearDisplayRestore(allocator);
        self.page.pending_display_navigation_restore = restore;
        self.page.pending_display_navigation_restore.?.source_session_revision = self.page.source_session_revision;
    }

    pub fn clearDisplayRestore(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page.pending_display_navigation_restore) |*restore| restore.deinit(allocator);
        self.page.pending_display_navigation_restore = null;
    }

    pub fn captureDisplayOverride(self: Controller, allocator: std.mem.Allocator) !void {
        const captured_revision = if (self.page.pending_display_navigation_restore) |restore|
            restore.captured_input_revision
        else
            return;
        if (captured_revision == self.page.display_navigation_input_revision) return;

        const repo_root = self.repo_root orelse {
            self.clearDisplayRestore(allocator);
            return;
        };
        const identity_matches = if (self.page.pending_display_navigation_restore) |restore|
            restore.source_session_revision == self.page.source_session_revision and
                restore.source_kind == sourceKind(self.source) and
                std.mem.eql(u8, restore.repo_root, repo_root)
        else
            false;
        if (!identity_matches) {
            self.clearDisplayRestore(allocator);
            return;
        }

        var latest = try self.view().captureAnchor(allocator) orelse {
            self.clearDisplayRestore(allocator);
            return;
        };
        errdefer latest.deinit(allocator);
        const restore = &self.page.pending_display_navigation_restore.?;
        if (restore.override) |*previous| previous.deinit(allocator);
        restore.override = latest;
        restore.captured_input_revision = self.page.display_navigation_input_revision;
    }

    pub fn clearDeferredSourceApply(self: Controller, allocator: std.mem.Allocator) void {
        var deferred = self.page.deferred_source_apply orelse return;
        self.page.deferred_source_apply = null;
        _ = self.page.load.clearPendingIfCurrent(.{ .diff_load = deferred.finished.generation });
        self.clearPendingReloadIfGeneration(allocator, deferred.finished.generation);
        self.page.auto_reload.finishMember(deferred.cycle_id, .deferred_source_apply);
        deferred.deinit(allocator);
    }

    /// Completes the deferred-source state machine entirely inside the Review
    /// owner. The returned value contains only shell-facing status/redraw data;
    /// this method consumes or transfers the deferred task payload itself.
    pub fn applyDeferredSource(
        self: Controller,
        allocator: std.mem.Allocator,
        background_blocked: bool,
    ) !?DeferredSourceApplyOutcome {
        const deferred = self.page.deferred_source_apply orelse return null;
        self.page.deferred_source_apply = null;
        defer self.page.auto_reload.finishMember(deferred.cycle_id, .deferred_source_apply);

        var finished = deferred.finished;
        var result_transferred = false;
        defer if (!result_transferred) finished.deinit(allocator);

        if (background_blocked) {
            _ = self.page.load.finishPending(.{ .diff_load = finished.generation });
            self.clearPendingReloadIfGeneration(allocator, finished.generation);
            return .{ .source = .{} };
        }

        finished.background_cycle_id = null;
        var applied = try self.applySourceFinished(allocator, &finished, false);
        result_transferred = applied.result_transferred;
        // The deferred owner, not App, owns the local completion payload. App
        // receives only shell-facing consequences and must never deinit it.
        applied.result_transferred = false;
        const owned_failure_message = if (applied.auto_reload_failure) |*failure| blk: {
            const message = try allocator.dupe(u8, failure.message);
            failure.message = message;
            break :blk message;
        } else null;
        return .{ .source = applied, .owned_failure_message = owned_failure_message };
    }

    pub fn prepareSourceLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        options: SourceLoadOptions,
    ) !ReviewUpdate {
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        if (options.kind != .watch) self.clearDeferredSourceApply(allocator);
        if (options.kind == .repo_switch) self.page.auto_reload.clearAcceptedSource();

        const request = try diff_source.cloneLoadRequest(allocator, .{
            .source = self.source,
            .repo_root = repo_root,
        });
        errdefer diff_source.freeLoadRequest(allocator, request);

        const generation = self.page.load.beginDiffLoad();
        errdefer _ = self.page.load.clearPendingIfCurrent(.{ .diff_load = generation });
        try self.beginPendingReload(allocator, generation, options.kind);
        errdefer self.clearPendingReloadIfGeneration(allocator, generation);

        const expected_fingerprint = if (options.kind == .watch and !options.clear_visible_state)
            if (self.page.auto_reload.accepted_source) |accepted| accepted.fingerprint else null
        else
            null;
        if (options.clear_visible_state) {
            self.clearSourceDisplay(allocator);
            self.page.load.state = .loading;
        }
        self.page.activation.markPending(.source);

        return .{ .command = .{ .source_load = .{
            .identity = identity,
            .request = request,
            .generation = generation,
            .expected_fingerprint = expected_fingerprint,
            .background_cycle_id = options.background_cycle_id,
        } } };
    }

    pub fn prepareRepoDiscovery(
        self: Controller,
        allocator: std.mem.Allocator,
        background_cycle_id: ?u64,
    ) !ReviewUpdate {
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        const generation = self.page.load.beginRepoDiscovery();
        self.clearPendingReload(allocator);
        self.clearSourceDisplay(allocator);
        self.page.load.state = .loading;
        self.page.activation.markPending(.source);
        return .{ .command = .{ .repo_discovery = .{
            .identity = identity,
            .generation = generation,
            .background_cycle_id = background_cycle_id,
        } } };
    }

    pub fn acceptRepoDiscoverySpawn(self: Controller, background_cycle_id: ?u64) void {
        if (background_cycle_id) |cycle_id| _ = self.page.auto_reload.markMemberStarted(cycle_id, .source);
    }

    pub fn rejectRepoDiscoverySpawn(self: Controller, generation: u64) void {
        _ = self.page.load.clearPendingIfCurrent(.{ .repo_discovery = generation });
        self.failActiveMember(.source);
    }

    pub fn acceptSourceSpawn(self: Controller, background_cycle_id: ?u64) void {
        if (background_cycle_id) |cycle_id| _ = self.page.auto_reload.markMemberStarted(cycle_id, .source);
    }

    pub fn prepareStatusLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        origin: git_backend.ReadOrigin,
        background_cycle_id: ?u64,
    ) !ReviewUpdate {
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        if (self.page.git_status.repo_root) |current_root| {
            if (std.mem.eql(u8, current_root, repo_root)) {
                self.invalidateStatusSnapshot();
            } else {
                self.dropStatusSnapshot(allocator);
            }
        } else {
            self.dropStatusSnapshot(allocator);
        }
        const owned_root = try allocator.dupe(u8, repo_root);
        self.page.status_load.begin(background_cycle_id);
        self.page.activation.markPending(.status);
        return .{ .command = .{ .status_load = .{
            .identity = identity,
            .repo_root = owned_root,
            .generation = self.page.status_load.generation,
            .origin = origin,
            .background_cycle_id = background_cycle_id,
        } } };
    }

    pub fn acceptStatusSpawn(self: Controller, background_cycle_id: ?u64) void {
        if (background_cycle_id) |cycle_id| _ = self.page.auto_reload.markMemberStarted(cycle_id, .status);
    }

    pub fn rejectStatusSpawn(self: Controller, background_cycle_id: ?u64) void {
        self.page.status_load.pending = null;
        self.page.status_load.markFailure(background_cycle_id != null and self.page.git_status.repo_root != null);
        self.failActiveMember(.status);
    }

    pub fn prepareBranchStatusLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        background_cycle_id: ?u64,
    ) !ReviewUpdate {
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        if (self.page.branch_status.repo_root) |current_root| {
            if (std.mem.eql(u8, current_root, repo_root)) {
                _ = self.page.branch_status_load.prepare(true);
            } else {
                self.invalidateBranchStatusSnapshot();
            }
        } else {
            self.invalidateBranchStatusSnapshot();
        }
        const owned_root = try allocator.dupe(u8, repo_root);
        self.page.branch_status_load.begin(background_cycle_id);
        self.page.activation.markPending(.branch);
        return .{ .command = .{ .branch_status_load = .{
            .identity = identity,
            .repo_root = owned_root,
            .generation = self.page.branch_status_load.generation,
            .background_cycle_id = background_cycle_id,
        } } };
    }

    pub fn acceptBranchStatusSpawn(self: Controller, background_cycle_id: ?u64) void {
        if (background_cycle_id) |cycle_id| _ = self.page.auto_reload.markMemberStarted(cycle_id, .branch);
    }

    pub fn rejectBranchStatusSpawn(self: Controller, background_cycle_id: ?u64) void {
        self.page.branch_status_load.pending = null;
        self.page.branch_status_load.markFailure(background_cycle_id != null and self.page.branch_status.repo_root != null);
        self.failActiveMember(.branch);
    }

    pub fn rejectSourceSpawn(self: Controller, allocator: std.mem.Allocator, generation: u64) void {
        _ = self.page.load.clearPendingIfCurrent(.{ .diff_load = generation });
        self.clearPendingReloadIfGeneration(allocator, generation);
        self.failActiveMember(.source);
    }

    /// Reconciles projection identity and, only when a read is required,
    /// transfers one owned task request to the shell. The pending page identity
    /// is a distinct clone so task and page never share allocator ownership.
    pub fn prepareProjection(self: Controller, allocator_opt: ?std.mem.Allocator) !ReviewUpdate {
        // Projection reconciliation can move or free the currently displayed
        // owner. A live drag borrows that owner, so even cache promotion and
        // no-target cleanup wait until release/cancel has ended the borrow.
        if (self.displayMutationBlockedByDrag()) return .{};

        const target = self.view().projectionTarget() orelse {
            if (self.view().canRetainDisplayedProjection()) return .{};
            if (self.page.pending_display_navigation_restore != null and !self.page.status_load.isFresh()) return .{};
            const allocator = allocator_opt orelse {
                if (!self.page.review_projection.hasPending() and
                    !self.page.review_projection.hasDisplayed() and
                    self.page.review_projection.cacheLen() == 0 and
                    self.page.pending_display_navigation_restore == null) return .{};
                return error.MissingAllocator;
            };
            self.reconcileCompletedSelectionForNoProjectionTarget(allocator);
            if (self.page.pending_display_navigation_restore != null) self.clearDisplayRestore(allocator);
            self.page.review_projection.clearPending(allocator);
            if (self.repo_root) |repo_root| {
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
                    repo_root,
                    sourceKind(self.source),
                    self.page.source_session_revision,
                    self.page.status_snapshot_revision,
                );
            } else {
                self.page.review_projection.clearDisplayed(allocator);
                self.page.review_projection.clearCache(allocator);
            }
            return .{};
        };

        const allocator = allocator_opt orelse return error.MissingAllocator;

        if (self.page.pending_display_navigation_restore != null and !self.view().pendingDisplayRestoreMatchesTarget(target)) {
            self.clearDisplayRestore(allocator);
        }
        const displayed_matches = self.page.review_projection.displayedMatches(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        );
        if (displayed_matches and
            (target.kind != .generated_added_file or
                self.page.review_projection.displayed.request().?.matchesRootIdentity(self.root_identity))) return .{};

        if (self.page.review_projection.cacheHas(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) {
            var local_navigation = if (self.page.pending_display_navigation_restore == null)
                try self.view().captureAnchor(allocator)
            else
                null;
            defer if (local_navigation) |*anchor| anchor.deinit(allocator);

            var hit = self.page.review_projection.takeCached(
                target.repo_root,
                target.path_key,
                target.kind,
                target.source_kind,
                self.page.source_session_revision,
                self.page.status_snapshot_revision,
            ) orelse unreachable;
            var hit_owned = true;
            defer if (hit_owned) hit.deinit(allocator);

            if (target.kind != .generated_added_file or hit.request.matchesRootIdentity(self.root_identity)) {
                self.reconcileCompletedSelectionForReady(allocator, &hit.value);
                self.page.review_projection.clearPending(allocator);
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
                    target.repo_root,
                    target.source_kind,
                    self.page.source_session_revision,
                    self.page.status_snapshot_revision,
                );
                self.page.review_projection.installReady(hit);
                hit_owned = false;
                self.reconcileInstalledProjectionNavigation(allocator, if (local_navigation) |*anchor| anchor else null);
                return .{};
            }
        }
        if (self.page.review_projection.pendingMatches(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) return .{};

        self.page.review_projection.clearPending(allocator);
        if (!self.view().displayedMatchesStableIdentity(target)) {
            self.clearCompletedSelection(allocator);
            self.page.review_projection.cacheOrClearDisplayed(
                allocator,
                target.repo_root,
                target.source_kind,
                self.page.source_session_revision,
                self.page.status_snapshot_revision,
            );
        }
        self.page.review_projection_next_id +%= 1;
        const request_id = self.page.review_projection_next_id;
        const identity = self.page.activation.currentIdentity() orelse return .{};

        const request_root_identity = if (target.kind == .generated_added_file) self.root_identity else null;
        var state_request = try review_projection.cloneRequestWithRootIdentity(
            allocator,
            identity,
            request_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
            request_root_identity,
        );
        errdefer state_request.deinit(allocator);

        var task_request = try review_projection.cloneRequestWithRootIdentity(
            allocator,
            identity,
            request_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
            request_root_identity,
        );
        errdefer task_request.deinit(allocator);

        self.page.review_projection.pending = state_request;
        state_request = undefined;
        return .{ .command = .{ .review_projection = task_request } };
    }

    /// Shell validation/allocation/spawn failure terminal for a prepared read.
    /// It only clears the matching page clone; the command/task owner frees its
    /// own request independently.
    pub fn rejectProjectionSpawn(self: Controller, allocator: std.mem.Allocator, request_id: u64) void {
        const pending_id = if (self.page.review_projection.pending) |request| request.id else return;
        if (pending_id == request_id) self.page.review_projection.clearPending(allocator);
    }

    /// Prepares optional syntax only for the current plain generated preview.
    /// The bundle remains `eligible` while the page-owned pending request is
    /// in flight, so immutable cache admission never needs to mutate an entry.
    pub fn prepareGeneratedSyntax(self: Controller, allocator: std.mem.Allocator) !?review_projection.GeneratedSyntaxRequest {
        if (!source_syntax_runtime.enabled) return null;
        const target = self.view().projectionTarget() orelse return null;
        if (target.kind != .generated_added_file) return null;

        const ready = switch (self.page.review_projection.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => return null,
        };
        if (!ready.request.matchesBorrowed(
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) return null;
        if (!ready.request.matchesRootIdentity(self.root_identity)) return null;
        const bundle = switch (ready.value) {
            .generated_added_file => |*bundle| bundle,
            else => return null,
        };
        switch (bundle.decoration) {
            .eligible => {},
            .terminal_plain, .decorated => return null,
        }
        const current_identity = self.page.activation.currentIdentity() orelse return null;

        if (self.page.review_projection.syntax_pending) |pending| {
            if (pending.projection_id == ready.request.id and
                pending.identity.origin == current_identity.origin and
                pending.identity.repo_epoch == current_identity.repo_epoch and
                pending.identity.activation_id == current_identity.activation_id and
                pending.root_identity.eql(ready.request.root_identity.?) and
                pending.expected_fingerprint.eql(bundle.fingerprint())) return null;
            self.page.review_projection.clearSyntaxPending(allocator);
        }

        self.page.review_projection.syntax_next_id +%= 1;
        if (self.page.review_projection.syntax_next_id == 0) self.page.review_projection.syntax_next_id = 1;
        var state_request = try review_projection.generatedSyntaxRequestForProjection(
            allocator,
            self.page.review_projection.syntax_next_id,
            current_identity,
            ready.request,
            bundle.fingerprint(),
        );
        errdefer state_request.deinit(allocator);
        const task_request = try review_projection.cloneGeneratedSyntaxRequest(allocator, state_request);
        self.page.review_projection.syntax_pending = state_request;
        return task_request;
    }

    pub fn rejectGeneratedSyntaxSpawn(self: Controller, allocator: std.mem.Allocator, request_id: u64) void {
        const pending_id = if (self.page.review_projection.syntax_pending) |request| request.id else return;
        if (pending_id == request_id) self.page.review_projection.clearSyntaxPending(allocator);
    }

    pub fn applyGeneratedSyntaxFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: *review_projection.GeneratedSyntaxFinished,
    ) void {
        const current_identity = self.page.activation.currentIdentity() orelse {
            if (self.page.review_projection.syntax_pending) |pending| {
                if (pending.matches(finished.request)) self.page.review_projection.clearSyntaxPending(allocator);
            }
            return;
        };
        if (current_identity.origin != finished.request.identity.origin or
            current_identity.repo_epoch != finished.request.identity.repo_epoch or
            current_identity.activation_id != finished.request.identity.activation_id)
        {
            if (self.page.review_projection.syntax_pending) |pending| {
                if (pending.matches(finished.request)) self.page.review_projection.clearSyntaxPending(allocator);
            }
            return;
        }
        const pending = self.page.review_projection.syntax_pending orelse return;
        if (!pending.matches(finished.request)) return;
        self.page.review_projection.clearSyntaxPending(allocator);
        const active_root = self.root_identity orelse return;
        if (!active_root.eql(finished.request.root_identity)) return;

        const target = self.view().projectionTarget() orelse return;
        if (target.kind != .generated_added_file) return;
        const ready = switch (self.page.review_projection.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => return,
        };
        if (ready.request.id != finished.request.projection_id or
            !ready.request.matchesRootIdentity(active_root) or
            !ready.request.matchesBorrowed(
                target.repo_root,
                target.path_key,
                target.kind,
                target.source_kind,
                self.page.source_session_revision,
                self.page.status_snapshot_revision,
            )) return;
        const bundle = switch (ready.value) {
            .generated_added_file => |*bundle| bundle,
            else => return,
        };
        if (!bundle.fingerprint().eql(finished.request.expected_fingerprint)) return;

        switch (finished.result) {
            .loaded => |spans| {
                const snapshot = finished.snapshot_fingerprint orelse {
                    bundle.decoration = .{ .terminal_plain = .snapshot_changed };
                    return;
                };
                if (!snapshot.eql(finished.request.expected_fingerprint) or
                    !snapshot.eql(bundle.fingerprint()))
                {
                    bundle.decoration = .{ .terminal_plain = .snapshot_changed };
                    return;
                }
                bundle.decoration = .{ .decorated = .{
                    .spans = spans,
                    .has_visible_syntax = review_projection.sourceSpansHaveVisibleSyntax(spans),
                } };
                finished.result = .stale;
            },
            .terminal_plain => |reason| bundle.decoration = .{ .terminal_plain = reason },
            .stale => bundle.decoration = .{ .terminal_plain = .snapshot_changed },
        }
    }

    fn reconcileInstalledProjectionNavigation(
        self: Controller,
        allocator: std.mem.Allocator,
        local_navigation: ?*const review_page.ReloadAnchor,
    ) void {
        if (self.page.pending_display_navigation_restore) |*restore| {
            self.restoreDisplayedNavigation(restore.authoritative());
            self.clearDisplayRestore(allocator);
        } else if (local_navigation) |anchor| {
            self.restoreDisplayedNavigation(anchor);
        } else {
            self.navigation.refreshSearchForSelectedFile();
        }
    }

    /// Accepts the Review-owned half of repository discovery and returns the
    /// only owned value allowed to cross into the App repository coordinator.
    pub fn applyRepoDiscoveryFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.RepoDiscoveryFinished,
    ) !DiscoveryApply {
        if (!self.acceptsIdentity(result.identity)) return .{};
        self.page.auto_reload.finishMember(result.background_cycle_id, .source);
        _ = self.page.load.finishPending(.{ .repo_discovery = result.generation });
        if (!self.page.load.isCurrent(result.generation)) return .{};

        switch (result.result) {
            .empty => unreachable,
            .discovered => |discovery| {
                result.result = .empty;
                return .{ .commit_discovery = discovery };
            },
            .failed => |message| try self.storeFailedMessage(allocator, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| try self.storeFailedMessage(allocator, message),
        }
        return .{};
    }

    /// Applies the narrow outcome returned by the App repository coordinator.
    /// The page owns load-state consequences; App owns only repository commit.
    pub fn applyRepoDiscoveryCommit(
        self: Controller,
        allocator: std.mem.Allocator,
        has_repository: bool,
        active: bool,
    ) DiscoveryCommitOutcome {
        if (!has_repository) {
            self.clearSourceDisplay(allocator);
            self.page.load.replaceEmpty(allocator, .no_repository);
            return .none;
        }
        if (!active) {
            self.page.load.state = .idle;
            return .none;
        }
        return .start_initial_read;
    }

    /// Accepts one status task result into the Review page. The caller retains
    /// ownership of the enclosing result and consumes the returned shell-facing
    /// diagnostic/redraw intent synchronously.
    pub fn applyStatusFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.StatusLoadFinished,
        background_blocked: bool,
    ) !CompletionApply {
        self.page.auto_reload.finishMember(result.background_cycle_id, .status);
        if (!self.acceptsIdentity(result.identity)) {
            _ = self.page.status_load.accept(result.generation);
            return .{};
        }
        if (background_blocked) {
            _ = self.page.status_load.accept(result.generation);
            return .{};
        }
        if (!self.page.status_load.accept(result.generation)) return .{};

        switch (result.result) {
            .empty => {
                const same_root = if (self.page.git_status.repo_root) |root|
                    std.mem.eql(u8, root, result.repo_root)
                else
                    false;
                if (!same_root or self.page.git_status.document.entries.len != 0) self.advanceStatusSnapshotRevision(allocator);
                self.page.status_load.markSuccess();
                _ = self.page.activation.finishMember(result.identity, .status, .fresh);
                self.page.git_status.clear();
                const prefer_first = self.page.pending_initial_first_visible_selection;
                self.page.pending_initial_first_visible_selection = false;
                return .{ .project_status = prefer_first };
            },
            .loaded => |*bundle| {
                switch (load_state.statusSnapshotReplaceDecision(
                    self.page.action_cursor.hasOwner(),
                    self.page.pending_initial_first_visible_selection,
                    self.page.git_status.repo_root,
                    result.repo_root,
                    self.page.git_status.document.eql(bundle.document),
                )) {
                    .skip_identical => {
                        self.page.status_load.markSuccess();
                        _ = self.page.activation.finishMember(result.identity, .status, .fresh);
                        return .{ .skip_redraw = true };
                    },
                    .replace_action_cursor,
                    .replace_pending_initial_selection,
                    .replace_no_snapshot,
                    .replace_root_mismatch,
                    .replace_changed,
                    => {},
                }
                self.advanceStatusSnapshotRevision(allocator);
                try self.page.git_status.replace(result.repo_root, bundle);
                self.page.status_load.markSuccess();
                _ = self.page.activation.finishMember(result.identity, .status, .fresh);
                result.result = .empty;
                const prefer_first = self.page.pending_initial_first_visible_selection;
                self.page.pending_initial_first_visible_selection = false;
                return .{ .project_status = prefer_first };
            },
            .failed => |message| return self.applyStatusFailure(allocator, result.identity, result.background_cycle_id, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| return self.applyStatusFailure(allocator, result.identity, result.background_cycle_id, message),
        }
    }

    fn applyStatusFailure(self: Controller, allocator: std.mem.Allocator, identity: app_page.RequestIdentity, background_cycle_id: ?u64, message: []const u8) CompletionApply {
        const retain = background_cycle_id != null and self.page.git_status.repo_root != null;
        self.page.status_load.markFailure(retain);
        _ = self.page.activation.finishMember(identity, .status, .failed);
        if (!retain) {
            if (self.page.git_status.repo_root != null or self.page.git_status.document.entries.len != 0) {
                self.advanceStatusSnapshotRevision(allocator);
            }
            self.page.git_status.clear();
        }
        self.page.pending_initial_first_visible_selection = false;
        return .{ .diagnostic = .{ .status_load_failed = message } };
    }

    pub fn applyBranchStatusFinished(
        self: Controller,
        result: *app_load.BranchStatusLoadFinished,
        background_blocked: bool,
    ) CompletionApply {
        self.page.auto_reload.finishMember(result.background_cycle_id, .branch);
        if (!self.acceptsIdentity(result.identity)) {
            _ = self.page.branch_status_load.accept(result.generation);
            return .{};
        }
        if (background_blocked) {
            _ = self.page.branch_status_load.accept(result.generation);
            return .{};
        }
        if (!self.page.branch_status_load.accept(result.generation)) return .{};

        switch (result.result) {
            .empty => {
                self.page.branch_status.clear();
                self.page.branch_status_load.markSuccess();
                _ = self.page.activation.finishMember(result.identity, .branch, .fresh);
            },
            .loaded => |*bundle| {
                const same_root = if (self.page.branch_status.repo_root) |root|
                    std.mem.eql(u8, root, result.repo_root) and self.page.branch_status.status.eql(bundle.status)
                else
                    false;
                if (same_root) {
                    self.page.branch_status_load.markSuccess();
                    _ = self.page.activation.finishMember(result.identity, .branch, .fresh);
                    return .{ .skip_redraw = true };
                }
                self.page.branch_status.replace(result.repo_root, bundle) catch {
                    self.page.branch_status.clear();
                    self.page.branch_status_load.markFailure(false);
                    _ = self.page.activation.finishMember(result.identity, .branch, .failed);
                    return .{ .diagnostic = .branch_status_parse_failed };
                };
                self.page.branch_status_load.markSuccess();
                _ = self.page.activation.finishMember(result.identity, .branch, .fresh);
                result.result = .empty;
            },
            .failed => |message| return self.applyBranchFailure(result.identity, result.background_cycle_id, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| return self.applyBranchFailure(result.identity, result.background_cycle_id, message),
        }
        return .{};
    }

    fn applyBranchFailure(self: Controller, identity: app_page.RequestIdentity, background_cycle_id: ?u64, message: []const u8) CompletionApply {
        const retain = background_cycle_id != null and self.page.branch_status.repo_root != null;
        self.page.branch_status_load.markFailure(retain);
        _ = self.page.activation.finishMember(identity, .branch, .failed);
        if (!retain) self.page.branch_status.clear();
        return .{ .diagnostic = .{ .branch_status_load_failed = message } };
    }

    /// Transfers a matching projection result into retained Review state. A
    /// true `result_transferred` means the caller must not deinitialize the
    /// task result because its request/value now belong to the page.
    pub fn applyProjectionFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) !ProjectionApply {
        if (!self.acceptsIdentity(result.request.identity)) return .{};
        const pending_id = if (self.page.review_projection.pending) |request| request.id else return .{};
        if (pending_id != result.request.id) return .{};

        const current = self.view().projectionTarget() orelse return .{};
        if (result.request.kind == .generated_added_file and
            !result.request.matchesRootIdentity(self.root_identity)) return .{};
        if (!result.request.matchesBorrowed(
            current.repo_root,
            current.path_key,
            current.kind,
            current.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) return .{};

        // Keep the pending request and displayed owner intact until the drag
        // transaction has copied its selection into owned memory. Only one
        // completion can match the single pending request; a duplicate is
        // rejected and remains the caller's cleanup responsibility.
        if (self.displayMutationBlockedByDrag()) {
            if (self.page.deferred_projection_apply != null) return .{};
            self.page.deferred_projection_apply = .{ .finished = result.* };
            return .{ .result_transferred = true };
        }

        var local_navigation = if (self.page.pending_display_navigation_restore == null)
            try self.view().captureAnchor(allocator)
        else
            null;
        defer if (local_navigation) |*anchor| anchor.deinit(allocator);

        switch (result.result) {
            .ready => |*ready| self.reconcileCompletedSelectionForReady(allocator, ready),
            .failed, .failed_static => self.clearCompletedSelection(allocator),
        }

        self.page.review_projection.clearPending(allocator);
        self.page.review_projection.cacheOrClearDisplayed(
            allocator,
            current.repo_root,
            current.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        );
        switch (result.result) {
            .ready => |ready| {
                self.page.review_projection.installReady(.{
                    .request = result.request,
                    .value = ready,
                });
                self.reconcileInstalledProjectionNavigation(allocator, if (local_navigation) |*anchor| anchor else null);
                return .{ .result_transferred = true };
            },
            .failed => |body| {
                self.page.review_projection.displayed = .{ .failed = .{
                    .request = result.request,
                    .body = body,
                } };
                self.clearDisplayRestore(allocator);
                return .{ .result_transferred = true };
            },
            .failed_static => |message| {
                var request = try review_projection.cloneRequestWithRootIdentity(
                    allocator,
                    result.request.identity,
                    result.request.id,
                    result.request.repo_root,
                    result.request.path_key,
                    result.request.kind,
                    result.request.source_kind,
                    result.request.source_session_revision,
                    result.request.status_snapshot_revision,
                    result.request.root_identity,
                );
                errdefer request.deinit(allocator);
                var body = try review_projection.statusBodyAlloc(allocator, result.request.path_key, "{s}", .{message});
                errdefer body.deinit(allocator);
                self.page.review_projection.displayed = .{ .failed = .{ .request = request, .body = body } };
                self.clearDisplayRestore(allocator);
                return .{};
            },
        }
    }

    /// Applies an owned projection completion after the live drag borrow has
    /// ended. The normal acceptance checks run again because a deferred source
    /// completion may already have advanced the session revision.
    pub fn applyDeferredProjection(
        self: Controller,
        allocator: std.mem.Allocator,
    ) !void {
        var deferred = self.page.deferred_projection_apply orelse return;
        self.page.deferred_projection_apply = null;

        var result_transferred = false;
        defer if (!result_transferred) deferred.deinit(allocator);
        result_transferred = (try self.applyProjectionFinished(allocator, &deferred.finished)).result_transferred;
    }

    pub fn applySourceFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: *app_load.DiffLoadFinished,
        background_blocked: bool,
    ) !SourceApply {
        if (background_blocked) {
            self.page.auto_reload.finishMember(finished.background_cycle_id, .source);
            _ = self.page.load.finishPending(.{ .diff_load = finished.generation });
            self.clearPendingReloadIfGeneration(allocator, finished.generation);
            return .{};
        }
        if ((finished.result == .loaded or finished.result == .empty) and self.displayMutationBlockedByDrag() and
            self.page.load.isCurrent(finished.generation) and self.page.deferred_source_apply == null)
        {
            if (finished.background_cycle_id) |cycle_id| {
                if (self.page.auto_reload.moveMember(cycle_id, .source, .deferred_source_apply)) {
                    self.page.deferred_source_apply = .{ .finished = finished.*, .cycle_id = cycle_id };
                    return .{ .result_transferred = true, .redraw = .skip };
                }
            }
        }
        self.page.auto_reload.finishMember(finished.background_cycle_id, .source);
        _ = self.page.load.finishPending(.{ .diff_load = finished.generation });
        if (!self.acceptsIdentity(finished.identity)) {
            self.clearPendingReloadIfGeneration(allocator, finished.generation);
            return .{};
        }
        if (!self.page.load.isCurrent(finished.generation)) return .{};
        var pending_reload = self.takePendingReloadIfGeneration(finished.generation);
        defer if (pending_reload) |*pending| pending.deinit(allocator);

        const had_loaded_before = self.navigation.view().activeLoadedDiffConst() != null;
        const had_action_cursor = self.page.action_cursor.hasOwner();
        var can_project_status = false;
        var outcome: SourceApply = .{};

        switch (finished.result) {
            .empty => {
                var acceptance_restore = if (pending_reload) |pending|
                    if (pending.kind == .watch) try self.view().captureDisplayRestore(allocator) else null
                else
                    null;
                errdefer if (acceptance_restore) |*restore| restore.deinit(allocator);
                self.clearSourceDisplayForReplacement(allocator);
                self.page.load.replaceEmpty(allocator, .no_changes);
                if (acceptance_restore) |restore| {
                    self.installDisplayRestore(allocator, restore);
                    acceptance_restore = null;
                }
                outcome.recovered_failure = self.acceptSourceFingerprint(content_fingerprint.Fingerprint.init(""));
                _ = self.page.activation.finishMember(finished.identity, .source, self.acceptedSourceMember());
                can_project_status = true;
            },
            .unchanged => |fingerprint| {
                outcome.recovered_failure = self.acceptSourceFingerprint(fingerprint);
                _ = self.page.activation.finishMember(finished.identity, .source, self.acceptedSourceMember());
                outcome.redraw = .skip_unless_recovered_failure_cleared;
                return outcome;
            },
            .loaded => |*bundle| {
                const current_loaded = self.navigation.view().activeLoadedDiffConst();
                const consumed_pending_is_watch = if (pending_reload) |pending| pending.kind == .watch else false;
                const texts_equal = consumed_pending_is_watch and if (current_loaded) |loaded|
                    std.mem.eql(u8, loaded.text, bundle.loaded.text)
                else
                    false;
                switch (load_state.watchReloadRebuildDecision(consumed_pending_is_watch, current_loaded != null, texts_equal)) {
                    .skip_rebuild_identical_text => {
                        outcome.recovered_failure = self.acceptSourceFingerprint(bundle.fingerprint);
                        _ = self.page.activation.finishMember(finished.identity, .source, self.acceptedSourceMember());
                        const prefer_first = !had_loaded_before and !had_action_cursor;
                        if (prefer_first and self.page.status_load.isPending()) {
                            self.page.pending_initial_first_visible_selection = true;
                        }
                        try self.applyStatusProjection(allocator, prefer_first);
                        return outcome;
                    },
                    .rebuild_not_watch, .rebuild_no_current_loaded, .rebuild_text_changed => {},
                }

                var acceptance_restore = if (consumed_pending_is_watch)
                    try self.view().captureDisplayRestore(allocator)
                else
                    null;
                errdefer if (acceptance_restore) |*restore| restore.deinit(allocator);
                self.clearSourceDisplayForReplacement(allocator);
                var loaded = bundle.loaded;
                var arena = bundle.takeArena();
                errdefer arena.deinit();
                try self.navigation.materializeReviewedFiles(allocator, &loaded);
                errdefer allocator.free(loaded.reviewed_files);
                // The Review page owns root disclosure across compatible
                // reloads. Always rematerialize the accepted load with that
                // state, even when no file filter is active.
                try loaded.rebuildVisibleNodes(
                    arena.allocator(),
                    self.page.viewer.root_disclosure,
                    self.page.review_display.hide_reviewed_files,
                    self.page.review_display.changed_file_filter,
                );
                self.page.load.replaceLoaded(allocator, .{
                    .arena = arena,
                    .loaded = loaded,
                    .reviewed_files_owned = true,
                });
                if (acceptance_restore) |restore| {
                    self.installDisplayRestore(allocator, restore);
                    acceptance_restore = null;
                }
                outcome.recovered_failure = self.acceptSourceFingerprint(bundle.fingerprint);
                _ = self.page.activation.finishMember(finished.identity, .source, self.acceptedSourceMember());

                const active_loaded = self.navigation.activeLoadedDiff().?;
                const restored_from_anchor = if (self.page.pending_display_navigation_restore) |*restore|
                    self.navigation.restoreReloadAnchor(active_loaded, restore.authoritative())
                else if (pending_reload) |*pending|
                    if (pending.anchor) |*anchor| self.navigation.restoreReloadAnchor(active_loaded, anchor) else false
                else
                    false;
                if (restored_from_anchor) {
                    self.navigation.clampSelection(active_loaded.document.files.len);
                    self.navigation.clampDiffNavigation();
                } else {
                    if (!had_loaded_before and !had_action_cursor) {
                        self.navigation.selectFirstVisibleFile(active_loaded);
                    } else if (self.page.action_cursor.hasOwner()) {
                        _ = self.navigation.remapActionCursor(active_loaded);
                    } else {
                        self.navigation.syncSidebarNodeToSelectedFile(active_loaded);
                    }
                    self.navigation.clampSelection(active_loaded.document.files.len);
                    if (self.page.review_display.hide_reviewed_files) {
                        self.navigation.reconcileSelectionAfterVisibleNodeChange(active_loaded);
                    }
                    self.navigation.clampDiffNavigation();
                    self.navigation.refreshSearchForSelectedFile();
                }
                can_project_status = true;
            },
            .failed => |message| {
                _ = self.page.activation.finishMember(finished.identity, .source, .failed);
                return try self.applySourceFailure(allocator, pending_reload, std.mem.trim(u8, message, " \t\r\n"));
            },
            .failed_static => |message| {
                _ = self.page.activation.finishMember(finished.identity, .source, .failed);
                return try self.applySourceFailure(allocator, pending_reload, message);
            },
        }

        const prefer_first = !had_loaded_before and !had_action_cursor;
        if (prefer_first and self.page.status_load.isPending()) self.page.pending_initial_first_visible_selection = true;
        if (can_project_status) try self.applyStatusProjection(allocator, prefer_first);
        return outcome;
    }

    fn applySourceFailure(
        self: Controller,
        allocator: std.mem.Allocator,
        pending_reload: ?review_page.PendingReload,
        message: []const u8,
    ) !SourceApply {
        if (pending_reload != null and pending_reload.?.kind == .watch) {
            if (self.page.auto_reload.markSourceFailure(message)) {
                return .{ .auto_reload_failure = .{
                    .identity = self.page.auto_reload.last_failure.?,
                    .message = message,
                } };
            }
            return .{ .redraw = .skip };
        }
        self.clearSourceDisplay(allocator);
        try self.storeFailedMessage(allocator, message);
        return .{};
    }

    fn acceptSourceFingerprint(self: Controller, fingerprint: content_fingerprint.Fingerprint) ?auto_reload.FailureIdentity {
        const recovered_failure = self.page.auto_reload.last_failure;
        self.page.auto_reload.acceptSource(fingerprint);
        return recovered_failure;
    }

    fn acceptedSourceMember(self: Controller) authority.MemberFreshness {
        return if (diff_source.sourceIsOneShotInput(self.source)) .immutable else .fresh;
    }

    pub fn restoreDisplayedNavigation(self: Controller, anchor: *const review_page.ReloadAnchor) void {
        self.page.viewer.diff_cursor = anchor.diff_cursor;
        if (self.navigation.view().selectedDiffCursorOffset() == null) {
            if (anchor.diff_cursor_offset) |offset| {
                const line_count = self.navigation.view().displayedDiffLineCount();
                if (line_count > 0) {
                    self.page.viewer.diff_cursor = self.navigation.view().selectedCoordinateAtOffset(@min(offset, line_count - 1)) orelse self.page.viewer.diff_cursor;
                }
            }
        }
        if (self.navigation.view().selectedDiffCursorOffset() == null) self.navigation.initializeDiffCursorForSelectedFile();
        self.page.viewer.diff_scroll = anchor.diff_scroll;
        self.page.viewer.diff_horizontal_scroll = anchor.diff_horizontal_scroll;
        self.page.viewer.sidebar_horizontal_scroll = anchor.sidebar_horizontal_scroll;
        self.navigation.clampDiffNavigation();
        self.navigation.keepDiffCursorVisible();
        self.navigation.restoreSearchFromReloadAnchor(anchor);
        self.navigation.clampSidebarHorizontalScroll();
        self.navigation.clampDiffHorizontalScrollToVisibleRows();
    }

    pub fn advanceSourceSessionRevision(self: Controller, allocator: ?std.mem.Allocator) void {
        if (allocator) |owner| {
            self.clearCompletedSelection(owner);
            self.page.review_projection.clearCache(owner);
        } else {
            std.debug.assert(self.page.review_projection.cacheLen() == 0);
            std.debug.assert(self.page.completed_selection == null);
        }
        self.page.source_session_revision +%= 1;
    }

    /// Projection cache validity relies on StatusDocument.eql comparing both
    /// staged and unstaged line statistics. A line-stat-only change must advance
    /// this revision and invalidate every retained projection.
    pub fn advanceStatusSnapshotRevision(self: Controller, allocator: ?std.mem.Allocator) void {
        if (allocator) |owner| {
            self.clearProjectionCompletedSelection(owner);
            self.page.review_projection.clearCache(owner);
        } else {
            std.debug.assert(self.page.review_projection.cacheLen() == 0);
            if (self.page.completed_selection) |completed| switch (completed.token.display) {
                .loaded => {},
                .cached_projection, .combined_projection, .generated_untracked => unreachable,
            };
        }
        self.page.status_snapshot_revision +%= 1;
    }

    pub fn storeFailedMessage(self: Controller, allocator: std.mem.Allocator, message: []const u8) !void {
        try self.page.load.replaceFailed(allocator, message);
    }

    /// Projection/session teardown for the current Review display. This does
    /// not revoke accepted source authority; callers choose the destructive or
    /// replacement transition below explicitly.
    pub fn clearLoadedDiff(self: Controller, allocator: ?std.mem.Allocator) void {
        if (allocator == null) std.debug.assert(self.page.review_projection.isEmpty());
        self.advanceSourceSessionRevision(allocator);
        self.navigation.clearDiffSelection();
        self.page.load.clearCurrent(allocator);
        if (allocator) |owned_allocator| {
            self.page.review_projection.deinit(owned_allocator);
            self.page.staged_hunks.clear(owned_allocator);
            self.clearDisplayRestore(owned_allocator);
        }
        self.page.viewer.diff_scroll = 0;
        self.page.viewer.diff_horizontal_scroll = 0;
        self.page.viewer.sidebar_horizontal_scroll = 0;
        self.page.viewer.diff_cursor = .{ .metadata = 0 };
        self.navigation.clearSearchMatch();
    }

    /// Destructive source transition: visible data and source authority are
    /// invalidated together.
    pub fn clearSourceDisplay(self: Controller, allocator: ?std.mem.Allocator) void {
        self.page.auto_reload.clearAcceptedSource();
        self.clearLoadedDiff(allocator);
    }

    pub fn replaceMissingRepository(self: Controller, allocator: std.mem.Allocator) void {
        self.clearSourceDisplay(allocator);
        self.page.load.replaceEmpty(allocator, .no_repository);
    }

    /// Accepted replacement transition: keep failure provenance until the new
    /// fingerprint is accepted, but prevent use of the old snapshot.
    pub fn clearSourceDisplayForReplacement(self: Controller, allocator: ?std.mem.Allocator) void {
        self.page.auto_reload.invalidateAcceptedSnapshot();
        self.clearLoadedDiff(allocator);
    }

    pub fn applyStatusProjection(self: Controller, allocator: std.mem.Allocator, prefer_first_visible_file: bool) !void {
        if (!diff_source.sourceAllowsStageProjection(self.source)) return;

        const status_document = self.page.git_status.document;
        if (status_document.entries.len == 0) {
            if (self.page.action_cursor.hasOwner() and
                (self.page.load.hasPending() or self.page.status_load.isPending())) return;
            if (self.navigation.activeLoadedDiff()) |loaded| {
                if (loaded.document.files.len == 0) {
                    self.clearLoadedDiff(allocator);
                    self.page.load.replaceEmpty(allocator, .no_changes);
                    return;
                }
                if (self.page.action_cursor.hasOwner()) {
                    _ = self.navigation.remapActionCursor(loaded);
                    return;
                }
            }
            return;
        }

        if (self.navigation.activeLoadedDiff()) |loaded| {
            try self.rebuildLoadedTreeWithStatus(allocator, loaded, prefer_first_visible_file);
            return;
        }

        switch (self.page.load.state) {
            .empty => |reason| if (reason == .no_changes and
                file_tree.statusOnlyEntryCount(status_document, .{ .files = &.{} }) > 0)
            {
                try self.createStatusOnlyLoadedSession(allocator, status_document);
            },
            else => {},
        }
    }

    fn rebuildLoadedTreeWithStatus(
        self: Controller,
        app_allocator: std.mem.Allocator,
        loaded: *loaded_diff.LoadedDiff,
        prefer_first_visible_file: bool,
    ) !void {
        const allocator = self.navigation.loadArenaAllocator() orelse return;
        const previous_path_key = self.navigation.view().selectedStagePathKey();
        try self.navigation.ensureTreeOrderScope(app_allocator);
        loaded.tree = try file_tree.buildWithOptions(allocator, loaded.document, self.page.git_status.document, .{
            .root = self.navigation.view().fileTreeRootOptions(),
            .stable_order = self.navigation.stableOrderOptions(app_allocator),
        });
        try loaded.rebuildVisibleNodes(
            allocator,
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        if (self.page.action_cursor.hasOwner()) {
            _ = self.navigation.remapActionCursor(loaded);
            return;
        }
        if (prefer_first_visible_file) {
            self.navigation.selectFirstVisibleFile(loaded);
        } else {
            if (previous_path_key) |path_key| {
                if (navigation.findNodeByPathKey(loaded, path_key)) |node_index| {
                    self.navigation.selectSidebarNode(loaded, node_index);
                    self.navigation.reconcileSelectionAfterVisibleNodeChange(loaded);
                    return;
                }
            }
            self.navigation.reconcileSelectionAfterVisibleNodeChange(loaded);
        }
    }

    pub fn createStatusOnlyLoadedSession(
        self: Controller,
        allocator: std.mem.Allocator,
        status_document: git_status.StatusDocument,
    ) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const document = diff_parser.DiffDocument{ .files = &.{} };
        try self.navigation.ensureTreeOrderScope(allocator);
        var loaded: loaded_diff.LoadedDiff = .{
            .text = "",
            .document = document,
            .file_text_eligibility = &.{},
            .tree = try file_tree.buildWithOptions(arena_allocator, document, status_document, .{
                .root = self.navigation.view().fileTreeRootOptions(),
                .stable_order = self.navigation.stableOrderOptions(allocator),
            }),
            .rendered_line_cache = try diff_view_model.RenderedLineCache.build(arena_allocator, document),
            .collapsed_hunks = &.{},
            .collapsed_dirs = .empty,
            .bytes = 0,
            .lines = 0,
        };
        try loaded.rebuildVisibleNodes(
            arena_allocator,
            self.page.viewer.root_disclosure,
            false,
            self.page.review_display.changed_file_filter,
        );

        self.advanceSourceSessionRevision(allocator);
        if (self.page.pending_display_navigation_restore) |*restore| {
            restore.source_session_revision = self.page.source_session_revision;
        }
        self.page.load.replaceLoaded(allocator, .{
            .arena = arena,
            .loaded = loaded,
            .reviewed_files_owned = false,
        });

        const active_loaded = self.navigation.activeLoadedDiff().?;
        var visible_index: usize = 0;
        while (visible_index < active_loaded.visibleNodeCount()) : (visible_index += 1) {
            const node_index = active_loaded.visibleNodeAt(visible_index) orelse continue;
            if (active_loaded.tree.nodes[node_index].target == .directory or active_loaded.tree.nodes[node_index].target == .repo_root) continue;
            self.page.viewer.selected_node = node_index;
            self.navigation.selectSidebarNode(active_loaded, node_index);
            break;
        }
        if (self.page.action_cursor.hasOwner()) _ = self.navigation.remapActionCursor(active_loaded);
        if (self.page.pending_display_navigation_restore) |*restore| {
            _ = self.navigation.restoreReloadAnchor(active_loaded, restore.authoritative());
        }
    }
};

pub fn sourceKind(source: diff_source.SourceMode) review_projection.SourceKind {
    return switch (source) {
        .unstaged => .unstaged,
        .cached => .cached,
        .stdin, .pager, .patch_file, .range, .no_index => .other,
    };
}

fn sourceIsUnstaged(source: diff_source.SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .cached, .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

fn isCombinedHunkProjectionCandidate(file: diff_parser.FileDiff, entry: git_status.StatusEntry) bool {
    if (file.is_binary or file.hunks.len == 0 or entry.isConflict()) return false;
    if (entry.index != .modified or entry.worktree != .modified) return false;
    if (diff_file.status(file) != .modified or diff_file.hasModeChange(file)) return false;
    return file_tree.stagePresenceFromEntry(entry) == .mixed;
}

fn testController(
    page: *review_page.ReviewPageState,
    status_message: *@import("../../state.zig").StatusMessage,
    source: diff_source.SourceMode,
) Controller {
    if (page.activation.currentIdentity() == null) {
        _ = page.activation.activate(0, .pending, .pending, .pending);
    }
    return .{
        .page = page,
        .navigation = .{
            .page = page,
            .repo_root = "/repo",
            .source = source,
            .layout = .{ .width = 80, .height = 24 },
            .diagnostics = .{ .target = status_message },
        },
        .source = source,
        .repo_root = "/repo",
    };
}

test "reload pending generation consumes only its owner" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller: Controller = .{
        .page = &page,
        .navigation = .{
            .page = &page,
            .repo_root = "/repo",
            .source = .unstaged,
            .layout = .{ .width = 80, .height = 24 },
            .diagnostics = .{ .target = &status_message },
        },
        .source = .unstaged,
        .repo_root = "/repo",
    };
    page.pending_reload = .{ .generation = 7, .kind = .manual };
    try std.testing.expect(controller.takePendingReloadIfGeneration(6) == null);
    try std.testing.expect(page.pending_reload != null);
    var pending = controller.takePendingReloadIfGeneration(7) orelse return error.ExpectedPendingReload;
    pending.deinit(allocator);
    try std.testing.expect(page.pending_reload == null);
}

test "owned Review update consumes command exactly once" {
    const allocator = std.testing.allocator;
    var request = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(0, 1),
        4,
        "/repo",
        "src/main.zig",
        .cached_diff,
        .unstaged,
        2,
        3,
    );
    var update: ReviewUpdate = .{ .command = .{ .review_projection = request } };
    request = undefined;
    var command = update.takeCommand() orelse return error.ExpectedCommand;
    update.deinit(allocator);
    command.deinit(allocator);
}

test "owned read command variants release every payload" {
    const allocator = std.testing.allocator;

    var discovery_update: ReviewUpdate = .{ .command = .{ .repo_discovery = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .generation = 1,
        .background_cycle_id = null,
    } } };
    discovery_update.deinit(allocator);

    var source_update: ReviewUpdate = .{ .command = .{ .source_load = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .request = try diff_source.cloneLoadRequest(allocator, .{ .source = .{ .range = "main...HEAD" }, .repo_root = "/repo" }),
        .generation = 1,
        .expected_fingerprint = null,
        .background_cycle_id = null,
    } } };
    source_update.deinit(allocator);

    var status_update: ReviewUpdate = .{ .command = .{ .status_load = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 2,
        .origin = .foreground,
        .background_cycle_id = null,
    } } };
    status_update.deinit(allocator);

    var branch_update: ReviewUpdate = .{ .command = .{ .branch_status_load = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 3,
        .background_cycle_id = null,
    } } };
    branch_update.deinit(allocator);

    var projection_update: ReviewUpdate = .{ .command = .{ .review_projection = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(0, 1),
        4,
        "/repo",
        "src/main.zig",
        .cached_diff,
        .unstaged,
        5,
        6,
    ) } };
    projection_update.deinit(allocator);
}

test "repository discovery transfers ownership only after Review acceptance" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const identity = page.activation.currentIdentity().?;
    const generation = page.load.beginRepoDiscovery();

    var finished: app_load.RepoDiscoveryFinished = .{
        .identity = identity,
        .generation = generation,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try allocator.dupe(u8, "/workspace"),
        } } },
    };
    defer finished.deinit(allocator);

    var applied = try controller.applyRepoDiscoveryFinished(allocator, &finished);
    defer applied.deinit(allocator);
    try std.testing.expect(finished.result == .empty);
    try std.testing.expect(page.load.pending == null);

    var discovery = applied.takeCommitDiscovery() orelse return error.ExpectedDiscoveryCommit;
    defer discovery.deinit(allocator);
    try std.testing.expectEqualStrings("/workspace", discovery.none.current_root);
    try std.testing.expect(applied.commit_discovery == null);
}

test "stale repository epoch retains discovery ownership with task completion" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const identity = page.activation.currentIdentity().?;
    const generation = page.load.beginRepoDiscovery();

    var finished: app_load.RepoDiscoveryFinished = .{
        .identity = app_page.RequestIdentity.review(identity.repo_epoch + 1, identity.activation_id),
        .generation = generation,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try allocator.dupe(u8, "/stale"),
        } } },
    };
    defer finished.deinit(allocator);

    var applied = try controller.applyRepoDiscoveryFinished(allocator, &finished);
    defer applied.deinit(allocator);
    try std.testing.expect(applied.commit_discovery == null);
    try std.testing.expect(finished.result == .discovered);
    try std.testing.expect(page.load.pending != null);
}

test "repository discovery commit leaves load policy with Review" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try std.testing.expectEqual(
        DiscoveryCommitOutcome.start_initial_read,
        controller.applyRepoDiscoveryCommit(allocator, true, true),
    );
    try std.testing.expectEqual(
        DiscoveryCommitOutcome.none,
        controller.applyRepoDiscoveryCommit(allocator, true, false),
    );
    try std.testing.expect(page.load.state == .idle);
    try std.testing.expectEqual(
        DiscoveryCommitOutcome.none,
        controller.applyRepoDiscoveryCommit(allocator, false, true),
    );
    try std.testing.expectEqual(load_state.EmptyReason.no_repository, page.load.state.empty);
}

test "source command allocation failure rolls back pending identities" {
    const backing = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var page: review_page.ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        };
        defer page.deinit(backing);
        var status_message = @import("../../state.zig").StatusMessage{};
        const controller = testController(&page, &status_message, .{ .range = "main...HEAD" });
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });

        try std.testing.expectError(error.OutOfMemory, controller.prepareSourceLoad(
            failing.allocator(),
            "/repo",
            .{ .clear_visible_state = false, .kind = .manual },
        ));
        try std.testing.expect(page.load.pending == null);
        try std.testing.expect(page.pending_reload == null);
    }
}

test "auxiliary command allocation failure does not create pending ownership" {
    const backing = std.testing.allocator;

    var status_page: review_page.ReviewPageState = .{};
    defer status_page.deinit(backing);
    var status_message = @import("../../state.zig").StatusMessage{};
    const status_controller = testController(&status_page, &status_message, .unstaged);
    var status_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, status_controller.prepareStatusLoad(
        status_failing.allocator(),
        "/repo",
        .foreground,
        null,
    ));
    try std.testing.expect(status_page.status_load.pending == null);

    var branch_page: review_page.ReviewPageState = .{};
    defer branch_page.deinit(backing);
    const branch_controller = testController(&branch_page, &status_message, .unstaged);
    var branch_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, branch_controller.prepareBranchStatusLoad(
        branch_failing.allocator(),
        "/repo",
        null,
    ));
    try std.testing.expect(branch_page.branch_status_load.pending == null);
}

test "projection command partial allocation failure leaves no pending clone" {
    const backing = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var page: review_page.ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        };
        defer page.deinit(backing);
        var status_bundle = try git_status.StatusBundle.parseOwned(backing, "MM a\x00");
        try page.git_status.replace("/repo", &status_bundle);
        var status_message = @import("../../state.zig").StatusMessage{};
        const controller = testController(&page, &status_message, .unstaged);
        try std.testing.expect(controller.view().projectionTarget() != null);
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });

        try std.testing.expectError(error.OutOfMemory, controller.prepareProjection(failing.allocator()));
        try std.testing.expect(page.review_projection.pending == null);
    }
}

test "read command reject terminals clear only matching page state" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.load.generation = 1;
    page.load.pending = .{ .repo_discovery = 1 };
    controller.rejectRepoDiscoverySpawn(1);
    try std.testing.expect(page.load.pending == null);

    _ = page.status_load.prepare(false);
    page.status_load.begin(null);
    controller.rejectStatusSpawn(null);
    try std.testing.expect(page.status_load.pending == null);

    _ = page.branch_status_load.prepare(false);
    page.branch_status_load.begin(null);
    controller.rejectBranchStatusSpawn(null);
    try std.testing.expect(page.branch_status_load.pending == null);

    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(0, 1),
        9,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        1,
        2,
    );
    controller.rejectProjectionSpawn(allocator, 8);
    try std.testing.expect(page.review_projection.pending != null);
    controller.rejectProjectionSpawn(allocator, 9);
    try std.testing.expect(page.review_projection.pending == null);

    page.load.generation = 11;
    page.load.pending = .{ .diff_load = 11 };
    page.pending_reload = .{ .generation = 11, .kind = .manual };
    controller.rejectSourceSpawn(allocator, 11);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
}

test "repository discovery preparation owns Review load state" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    _ = page.activation.activate(4, .pending, .pending, .pending);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareRepoDiscovery(allocator, 9);
    defer update.deinit(allocator);
    const command = update.command orelse return error.ExpectedCommand;

    try std.testing.expect(command == .repo_discovery);
    try std.testing.expectEqual(@as(?u64, 9), command.repo_discovery.background_cycle_id);
    try std.testing.expect(page.load.state == .loading);
    try std.testing.expectEqual(
        load_state.PendingLoad{ .repo_discovery = command.repo_discovery.generation },
        page.load.pending.?,
    );
}

test "projection cache revisits A after B without a third read command" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00?? b\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var first = try controller.prepareProjection(allocator);
    defer first.deinit(allocator);
    const a_lines = try finishGeneratedProjection(controller, allocator, &first, "a");

    page.viewer.selected_target = .{ .status_only = 1 };
    var second = try controller.prepareProjection(allocator);
    defer second.deinit(allocator);
    try std.testing.expect(page.review_projection.cacheHas("/repo", "a", .generated_added_file, .unstaged, 0, 0));
    _ = try finishGeneratedProjection(controller, allocator, &second, "b");

    page.viewer.selected_target = .{ .status_only = 0 };
    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.activation.currentIdentity().?,
        99,
        "/repo",
        "b",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );
    var late: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            99,
            "/repo",
            "b",
            .generated_added_file,
            .unstaged,
            0,
            0,
        ),
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "b", "late\n") } },
    };
    defer late.deinit(allocator);
    var revisit = try controller.prepareProjection(allocator);
    defer revisit.deinit(allocator);
    try std.testing.expect(revisit.command == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expectEqual(a_lines, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
    try std.testing.expect(page.review_projection.cacheHas("/repo", "b", .generated_added_file, .unstaged, 0, 0));

    const late_apply = try controller.applyProjectionFinished(allocator, &late);
    try std.testing.expect(!late_apply.result_transferred);
    try std.testing.expectEqual(a_lines, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
}

test "projection cache survives selecting a file that needs no projection" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwo()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? c\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var first = try controller.prepareProjection(allocator);
    defer first.deinit(allocator);
    const c_lines = try finishGeneratedProjection(controller, allocator, &first, "c");

    page.viewer.selected_target = .{ .diff_file = 0 };
    var ordinary = try controller.prepareProjection(allocator);
    defer ordinary.deinit(allocator);
    try std.testing.expect(ordinary.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(page.review_projection.cacheHas("/repo", "c", .generated_added_file, .unstaged, 0, 0));

    page.viewer.selected_target = .{ .status_only = 0 };
    var revisit = try controller.prepareProjection(allocator);
    defer revisit.deinit(allocator);
    try std.testing.expect(revisit.command == null);
    try std.testing.expectEqual(c_lines, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
}

test "full projection cache promotes LRU before old display admission" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00?? b\x00?? c\x00?? d\x00?? e\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const paths = [_][]const u8{ "a", "b", "c", "d" };
    var a_lines: [*]const u8 = undefined;
    for (paths, 0..) |path, index| {
        const ready = try testGeneratedReady(allocator, index + 1, path, 0, 0);
        if (index == 0) a_lines = ready.value.generated_added_file.source.bytes.ptr;
        page.review_projection.installReady(ready);
        page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    }
    try std.testing.expectEqual(review_projection.max_cached_entries, page.review_projection.cacheLen());

    page.review_projection.installReady(try testGeneratedReady(allocator, 5, "e", 0, 0));
    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.activation.currentIdentity().?,
        99,
        "/repo",
        "late",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );

    // captureAnchor performs the one permitted allocation. If old-display
    // admission unexpectedly needs cache metadata after removing the hit, the
    // next allocation fails; the hit must still remain installable either way.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var update = try controller.prepareProjection(failing.allocator());
    defer update.deinit(allocator);

    try std.testing.expect(update.command == null);
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expectEqual(a_lines, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
    try std.testing.expectEqual(review_projection.max_cached_entries, page.review_projection.cacheLen());
    try std.testing.expect(page.review_projection.cacheHas("/repo", "e", .generated_added_file, .unstaged, 0, 0));
    try std.testing.expect(page.review_projection.cacheRetainedBytes() <= review_projection.max_cached_retained_bytes);
}

test "generated syntax lifecycle separates pending decorated terminal and cache states" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 9, .inode = 17 };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    var controller = testController(&page, &status_message, .unstaged);
    controller.root_identity = root;

    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithRootIdentity(
            allocator,
            page.activation.currentIdentity().?,
            11,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            root,
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "const value = 1;\n") },
    });

    var task_request = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRequest;
    defer task_request.deinit(allocator);
    try std.testing.expect(page.review_projection.hasSyntaxPending());
    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);

    const entries = try allocator.dupe(@import("../../../syntax/source.zig").LineEntry, &.{.{
        .line_index = 0,
        .span_start = 0,
        .span_count = 1,
    }});
    const spans = try allocator.dupe(@import("../../../syntax/token.zig").TokenSpan, &.{.{
        .start = 0,
        .end = 5,
        .role = .keyword,
    }});
    var finished = review_projection.GeneratedSyntaxFinished{
        .request = try review_projection.cloneGeneratedSyntaxRequest(allocator, task_request),
        .snapshot_fingerprint = task_request.expected_fingerprint,
        .result = .{ .loaded = .{ .line_entries = entries, .spans = spans } },
    };
    defer finished.deinit(allocator);
    controller.applyGeneratedSyntaxFinished(allocator, &finished);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
    const decorated_bundle = &page.review_projection.displayed.ready.value.generated_added_file;
    try std.testing.expect(decorated_bundle.decoration == .decorated);
    try std.testing.expect(decorated_bundle.decoration.hasVisibleSyntax());
    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);

    page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    var promoted = try controller.prepareProjection(allocator);
    defer promoted.deinit(allocator);
    try std.testing.expect(promoted.command == null);
    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);

    page.review_projection.displayed.ready.value.generated_added_file.decoration.deinit(allocator);
    page.review_projection.displayed.ready.value.generated_added_file.decoration = .{ .terminal_plain = .provider_unavailable };
    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);
}

test "generated syntax completion after cache admission cannot mutate immutable entry" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 4, .inode = 8 };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    var controller = testController(&page, &status_message, .unstaged);
    controller.root_identity = root;
    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithRootIdentity(
            allocator,
            page.activation.currentIdentity().?,
            31,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            root,
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "const x = 1;\n") },
    });
    var task_request = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRequest;
    defer task_request.deinit(allocator);
    page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    var late = review_projection.GeneratedSyntaxFinished{
        .request = try review_projection.cloneGeneratedSyntaxRequest(allocator, task_request),
        .snapshot_fingerprint = task_request.expected_fingerprint,
        .result = .{ .loaded = .empty() },
    };
    defer late.deinit(allocator);
    controller.applyGeneratedSyntaxFinished(allocator, &late);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    var promoted = try controller.prepareProjection(allocator);
    defer promoted.deinit(allocator);
    try std.testing.expect(promoted.command == null);
    try std.testing.expect(page.review_projection.displayed.ready.value.generated_added_file.decoration == .eligible);
    var retried = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRetry;
    defer retried.deinit(allocator);
}

test "status line stats change invalidates retained projection cache" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var initial = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try initial.attachLineStats(&.{.{ .path_key = "a", .stats = .{ .added = 1, .removed = 1 } }});
    try page.git_status.replace("/repo", &initial);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(try testGeneratedReady(allocator, 1, "a", 0, 0));
    page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    _ = page.status_load.prepare(false);
    page.status_load.begin(null);
    var identical = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try identical.attachLineStats(&.{.{ .path_key = "a", .stats = .{ .added = 1, .removed = 1 } }});
    var identical_finished: app_load.StatusLoadFinished = .{
        .identity = page.activation.currentIdentity().?,
        .generation = page.status_load.generation,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = identical },
    };
    identical = undefined;
    defer identical_finished.deinit(allocator);
    _ = try controller.applyStatusFinished(allocator, &identical_finished, false);
    try std.testing.expectEqual(@as(u64, 0), page.status_snapshot_revision);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    _ = page.status_load.prepare(false);
    page.status_load.begin(null);
    var changed = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try changed.attachLineStats(&.{.{ .path_key = "a", .stats = .{ .added = 2, .removed = 1 } }});
    var finished: app_load.StatusLoadFinished = .{
        .identity = page.activation.currentIdentity().?,
        .generation = page.status_load.generation,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = changed },
    };
    changed = undefined;
    defer finished.deinit(allocator);

    _ = try controller.applyStatusFinished(allocator, &finished, false);
    try std.testing.expectEqual(@as(u64, 1), page.status_snapshot_revision);
    try std.testing.expectEqual(@as(usize, 0), page.review_projection.cacheLen());
}

test "source session replacement clears populated projection cache" {
    const allocator = std.testing.allocator;
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    defer status_bundle.deinit();
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(try testGeneratedReady(allocator, 1, "a", 0, 0));
    page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    try controller.createStatusOnlyLoadedSession(allocator, status_bundle.document);
    try std.testing.expectEqual(@as(u64, 1), page.source_session_revision);
    try std.testing.expectEqual(@as(usize, 0), page.review_projection.cacheLen());
    try std.testing.expect(!page.review_projection.cacheHas("/repo", "a", .generated_added_file, .unstaged, 0, 0));
}

test "old revision display is not admitted when fresh completion replaces it" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(try testGeneratedReady(allocator, 1, "a", 0, 0));
    controller.advanceStatusSnapshotRevision(allocator);
    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.activation.currentIdentity().?,
        2,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        0,
        1,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            2,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            1,
        ),
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "fresh\n") } },
    };
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);

    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;
    try std.testing.expectEqual(@as(usize, 0), page.review_projection.cacheLen());
    try std.testing.expectEqual(@as(u64, 1), page.review_projection.displayed.ready.request.status_snapshot_revision);
}

fn finishGeneratedProjection(
    controller: Controller,
    allocator: std.mem.Allocator,
    update: *ReviewUpdate,
    path: []const u8,
) ![*]const u8 {
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;

    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, path, "one\ntwo\n") } },
    };
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const lines = finished.result.ready.generated_added_file.source.bytes.ptr;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;
    return lines;
}

fn testGeneratedReady(
    allocator: std.mem.Allocator,
    id: usize,
    path: []const u8,
    source_session_revision: u64,
    status_snapshot_revision: u64,
) !review_projection.ReadyDisplay {
    var request = try review_projection.cloneRequest(
        allocator,
        app_page.RequestIdentity.review(0, 1),
        id,
        "/repo",
        path,
        .generated_added_file,
        .unstaged,
        source_session_revision,
        status_snapshot_revision,
    );
    errdefer request.deinit(allocator);
    return .{
        .request = request,
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, path, "one\ntwo\n") },
    };
}

fn testGeneratedCandidate(
    controller: Controller,
    allocator: std.mem.Allocator,
    bundle: *const review_projection.GeneratedFileBundle,
) !review_selection.CompletedSelection {
    const ready: review_projection.Ready = .{ .generated_added_file = bundle.* };
    const token = controller.contentTokenForReady(&ready) orelse return error.ExpectedContentToken;
    var drag = @import("../../../diff/selection.zig").DragSelection.init(
        .{ .generated_file = .{ .path_key = bundle.path } },
        .new,
        .{ .hunk_index = 0, .line_index = 0, .leading = 0, .trailing = 3 },
    );
    drag.mode = .character;
    drag.moved = true;
    return review_selection.buildGenerated(allocator, token, bundle.path, &bundle.source, drag);
}

test "projection completion defers without moving displayed ownership during live drag" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;

    page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "one\ntwo\n") } },
    };
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);

    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;
    try std.testing.expect(page.deferred_projection_apply != null);
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expect(!page.review_projection.hasDisplayed());

    var duplicate: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            page.review_projection.pending.?.id,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
        ),
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "duplicate\n") } },
    };
    defer duplicate.deinit(allocator);
    const duplicate_apply = try controller.applyProjectionFinished(allocator, &duplicate);
    try std.testing.expect(!duplicate_apply.result_transferred);
    try std.testing.expect(page.deferred_projection_apply != null);

    // Reconciliation, including a cache lookup, is inert for the duration of
    // the borrow. The deferred completion remains the only result owner.
    var while_dragging = try controller.prepareProjection(allocator);
    defer while_dragging.deinit(allocator);
    try std.testing.expect(while_dragging.command == null);
    try std.testing.expect(page.deferred_projection_apply != null);

    page.selection_owner = .none;
    try controller.applyDeferredProjection(allocator);
    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.hasDisplayed());
}

test "projection failed terminals defer through the same owned result slot" {
    const allocator = std.testing.allocator;
    var status_message = @import("../../state.zig").StatusMessage{};

    var owned_page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer owned_page.deinit(allocator);
    var owned_status = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try owned_page.git_status.replace("/repo", &owned_status);
    const owned_controller = testController(&owned_page, &status_message, .unstaged);
    var owned_update = try owned_controller.prepareProjection(allocator);
    defer owned_update.deinit(allocator);
    var owned_command = owned_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const owned_request = switch (owned_command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    owned_command = undefined;
    owned_page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var failed: app_load.ReviewProjectionFinished = .{
        .request = owned_request,
        .result = .{ .failed = try review_projection.statusBodyAlloc(allocator, "a", "{s}", .{"failed"}) },
    };
    const failed_apply = try owned_controller.applyProjectionFinished(allocator, &failed);
    try std.testing.expect(failed_apply.result_transferred);
    owned_page.selection_owner = .none;
    try owned_controller.applyDeferredProjection(allocator);
    try std.testing.expect(owned_page.review_projection.displayed == .failed);

    var static_page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer static_page.deinit(allocator);
    var static_status = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try static_page.git_status.replace("/repo", &static_status);
    const static_controller = testController(&static_page, &status_message, .unstaged);
    var static_update = try static_controller.prepareProjection(allocator);
    defer static_update.deinit(allocator);
    var static_command = static_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const static_request = switch (static_command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    static_command = undefined;
    static_page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var failed_static: app_load.ReviewProjectionFinished = .{
        .request = static_request,
        .result = .{ .failed_static = "failed static" },
    };
    const static_apply = try static_controller.applyProjectionFinished(allocator, &failed_static);
    try std.testing.expect(static_apply.result_transferred);
    static_page.selection_owner = .none;
    try static_controller.applyDeferredProjection(allocator);
    try std.testing.expect(static_page.review_projection.displayed == .failed);
}

test "cached and combined ready completions use the live drag deferral slot" {
    const allocator = std.testing.allocator;
    var status_message = @import("../../state.zig").StatusMessage{};

    var cached_page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer cached_page.deinit(allocator);
    var cached_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try cached_page.git_status.replace("/repo", &cached_status);
    const cached_controller = testController(&cached_page, &status_message, .unstaged);
    var cached_update = try cached_controller.prepareProjection(allocator);
    defer cached_update.deinit(allocator);
    var cached_command = cached_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const cached_request = switch (cached_command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    cached_command = undefined;
    cached_page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var cached_finished: app_load.ReviewProjectionFinished = .{
        .request = cached_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, test_support.diff_cached_projection) } },
    };
    const cached_apply = try cached_controller.applyProjectionFinished(allocator, &cached_finished);
    try std.testing.expect(cached_apply.result_transferred);
    try std.testing.expect(cached_page.deferred_projection_apply != null);
    cached_page.selection_owner = .none;
    try cached_controller.applyDeferredProjection(allocator);
    try std.testing.expect(cached_page.review_projection.displayed.ready.value == .cached_diff);

    var combined_page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer combined_page.deinit(allocator);
    var combined_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try combined_page.git_status.replace("/repo", &combined_status);
    combined_page.status_load.markSuccess();
    const combined_controller = testController(&combined_page, &status_message, .unstaged);
    var combined_update = try combined_controller.prepareProjection(allocator);
    defer combined_update.deinit(allocator);
    var combined_command = combined_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const combined_request = switch (combined_command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    combined_command = undefined;
    var cached_bundle = try app_load.buildLoadedBundle(allocator, test_support.diff_cached_projection);
    var cached_owned = true;
    defer if (cached_owned) cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, test_support.diff_unstaged_projection);
    var unstaged_owned = true;
    defer if (unstaged_owned) unstaged_bundle.deinit();
    var projection_arena = std.heap.ArenaAllocator.init(allocator);
    var projection_owned = true;
    defer if (projection_owned) projection_arena.deinit();
    const projection = try diff_hunk_projection.build(
        projection_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    combined_page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var combined_finished: app_load.ReviewProjectionFinished = .{
        .request = combined_request,
        .result = .{ .ready = .{ .combined_hunks = .{
            .arena = projection_arena,
            .projection = projection,
            .cached_bundle = cached_bundle,
            .unstaged_bundle = unstaged_bundle,
        } } },
    };
    const combined_apply = try combined_controller.applyProjectionFinished(allocator, &combined_finished);
    try std.testing.expect(combined_apply.result_transferred);
    projection_owned = false;
    cached_owned = false;
    unstaged_owned = false;
    try std.testing.expect(combined_page.deferred_projection_apply != null);
    combined_page.selection_owner = .none;
    try combined_controller.applyDeferredProjection(allocator);
    try std.testing.expect(combined_page.review_projection.displayed.ready.value == .combined_hunks);
}

test "either inert combined component defers caches promotes and deinits exactly once" {
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
        var status_message = @import("../../state.zig").StatusMessage{};
        var page: review_page.ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        };
        defer page.deinit(allocator);
        var status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
        try page.git_status.replace("/repo", &status);
        page.status_load.markSuccess();
        const controller = testController(&page, &status_message, .unstaged);
        var update = try controller.prepareProjection(allocator);
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
        const request = switch (command) {
            .review_projection => |owned| owned,
            else => return error.ExpectedProjectionCommand,
        };
        command = undefined;

        var cached = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) invalid_patch else valid_patch);
        var cached_owned = true;
        defer if (cached_owned) cached.deinit();
        var unstaged = try app_load.buildLoadedBundle(allocator, if (cached_is_invalid) valid_patch else invalid_patch);
        var unstaged_owned = true;
        defer if (unstaged_owned) unstaged.deinit();
        page.selection_owner = .{ .diff = .init(
            .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .new,
            .{ .hunk_index = 0, .line_index = 0 },
        ) };
        var finished: app_load.ReviewProjectionFinished = .{
            .request = request,
            .result = .{ .ready = .{ .inert_combined = .{
                .cached_bundle = cached,
                .unstaged_bundle = unstaged,
            } } },
        };
        const applied = try controller.applyProjectionFinished(allocator, &finished);
        try std.testing.expect(applied.result_transferred);
        cached_owned = false;
        unstaged_owned = false;
        try std.testing.expect(page.deferred_projection_apply != null);
        try std.testing.expect(!page.review_projection.hasDisplayed());

        page.selection_owner = .none;
        try controller.applyDeferredProjection(allocator);
        try std.testing.expect(page.deferred_projection_apply == null);
        try std.testing.expect(page.review_projection.displayed.ready.value == .inert_combined);

        page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
        try std.testing.expect(page.review_projection.cacheHas("/repo", "a", .combined_hunks, .unstaged, 0, 0));
        var promoted = try controller.prepareProjection(allocator);
        defer promoted.deinit(allocator);
        try std.testing.expect(promoted.command == null);
        try std.testing.expect(page.review_projection.displayed.ready.value == .inert_combined);
    }
}

test "projection cache promotion and no-target clear wait for live drag release" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(try testGeneratedReady(allocator, 1, "a", 0, 0));
    page.review_projection.cacheOrClearDisplayed(allocator, "/repo", .unstaged, 0, 0);
    page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var blocked_promotion = try controller.prepareProjection(allocator);
    defer blocked_promotion.deinit(allocator);
    try std.testing.expect(blocked_promotion.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(page.review_projection.cacheHas("/repo", "a", .generated_added_file, .unstaged, 0, 0));

    page.selection_owner = .none;
    var promoted = try controller.prepareProjection(allocator);
    defer promoted.deinit(allocator);
    try std.testing.expect(promoted.command == null);
    try std.testing.expect(page.review_projection.hasDisplayed());

    page.selection_owner = .{ .diff = .init(
        .{ .generated_file = .{ .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    page.viewer.selected_target = .{ .diff_file = 0 };
    var blocked_clear = try controller.prepareProjection(allocator);
    defer blocked_clear.deinit(allocator);
    try std.testing.expect(blocked_clear.command == null);
    try std.testing.expect(page.review_projection.hasDisplayed());

    page.selection_owner = .none;
    var cleared = try controller.prepareProjection(allocator);
    defer cleared.deinit(allocator);
    try std.testing.expect(cleared.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(page.review_projection.cacheHas("/repo", "a", .generated_added_file, .unstaged, 0, 0));
}

test "source replacement before deferred projection rejects and frees the stale result" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "stale\n") } },
    };
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    // This is the ordering used by App's common drain: source replacement
    // advances the revision and clears projection state before the deferred
    // projection is reconsidered.
    controller.clearLoadedDiff(allocator);
    try std.testing.expectEqual(@as(u64, 1), page.source_session_revision);
    try controller.applyDeferredProjection(allocator);
    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
}

test "projection candidate survives exact rebuild and clears on changed content basis" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(try testGeneratedReady(allocator, 1, "a", 0, 0));
    const displayed = &page.review_projection.displayed.ready.value.generated_added_file;
    page.completed_selection = try testGeneratedCandidate(controller, allocator, displayed);

    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.activation.currentIdentity().?,
        2,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );
    var exact: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            2,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
        ),
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "one\ntwo\n") } },
    };
    var exact_owned = true;
    defer if (exact_owned) exact.deinit(allocator);
    const exact_apply = try controller.applyProjectionFinished(allocator, &exact);
    try std.testing.expect(exact_apply.result_transferred);
    exact_owned = false;
    try std.testing.expect(page.completed_selection != null);

    page.review_projection.pending = try review_projection.cloneRequest(
        allocator,
        page.activation.currentIdentity().?,
        3,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );
    var changed: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            3,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
        ),
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "changed\n") } },
    };
    var changed_owned = true;
    defer if (changed_owned) changed.deinit(allocator);
    const changed_apply = try controller.applyProjectionFinished(allocator, &changed);
    try std.testing.expect(changed_apply.result_transferred);
    changed_owned = false;
    try std.testing.expect(page.completed_selection == null);
}

test "deferred source terminals consume blocked and accepted ownership" {
    const allocator = std.testing.allocator;
    var status_message = @import("../../state.zig").StatusMessage{};

    var blocked_page: review_page.ReviewPageState = .{};
    defer blocked_page.deinit(allocator);
    blocked_page.auto_reload = .init(.inherit, .{}, .unstaged);
    const blocked_cycle = blocked_page.auto_reload.beginCycle().?;
    try std.testing.expect(blocked_page.auto_reload.markMemberStarted(blocked_cycle, .source));
    try std.testing.expect(blocked_page.auto_reload.moveMember(blocked_cycle, .source, .deferred_source_apply));
    blocked_page.load.generation = 1;
    blocked_page.load.pending = .{ .diff_load = 1 };
    blocked_page.pending_reload = .{ .generation = 1, .kind = .watch };
    blocked_page.deferred_source_apply = .{
        .cycle_id = blocked_cycle,
        .finished = .{ .identity = app_page.RequestIdentity.review(0, 1), .generation = 1, .result = .{ .failed_static = "blocked" } },
    };
    const blocked_controller = testController(&blocked_page, &status_message, .unstaged);
    var blocked_applied = (try blocked_controller.applyDeferredSource(allocator, true)) orelse return error.ExpectedDeferredApply;
    defer blocked_applied.deinit(allocator);
    try std.testing.expect(blocked_page.deferred_source_apply == null);
    try std.testing.expect(blocked_page.load.pending == null);
    try std.testing.expect(blocked_page.pending_reload == null);
    try std.testing.expect(blocked_page.auto_reload.background_cycle == null);

    var accepted_page: review_page.ReviewPageState = .{};
    defer accepted_page.deinit(allocator);
    accepted_page.auto_reload = .init(.inherit, .{}, .unstaged);
    const accepted_cycle = accepted_page.auto_reload.beginCycle().?;
    try std.testing.expect(accepted_page.auto_reload.markMemberStarted(accepted_cycle, .source));
    try std.testing.expect(accepted_page.auto_reload.moveMember(accepted_cycle, .source, .deferred_source_apply));
    accepted_page.load.generation = 2;
    accepted_page.load.pending = .{ .diff_load = 2 };
    accepted_page.pending_reload = .{ .generation = 2, .kind = .watch };
    accepted_page.deferred_source_apply = .{
        .cycle_id = accepted_cycle,
        .finished = .{
            .identity = app_page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .unchanged = content_fingerprint.Fingerprint.init("same") },
        },
    };
    const accepted_controller = testController(&accepted_page, &status_message, .unstaged);
    var applied = (try accepted_controller.applyDeferredSource(allocator, false)) orelse return error.ExpectedDeferredApply;
    defer applied.deinit(allocator);
    try std.testing.expectEqual(RedrawDisposition.skip_unless_recovered_failure_cleared, applied.source.redraw);
    try std.testing.expect(accepted_page.deferred_source_apply == null);
    try std.testing.expect(accepted_page.load.pending == null);
    try std.testing.expect(accepted_page.pending_reload == null);
    try std.testing.expect(accepted_page.auto_reload.background_cycle == null);

    const failure_cycle = accepted_page.auto_reload.beginCycle().?;
    try std.testing.expect(accepted_page.auto_reload.markMemberStarted(failure_cycle, .source));
    try std.testing.expect(accepted_page.auto_reload.moveMember(failure_cycle, .source, .deferred_source_apply));
    accepted_page.load.generation = 3;
    accepted_page.load.pending = .{ .diff_load = 3 };
    accepted_page.pending_reload = .{ .generation = 3, .kind = .watch };
    accepted_page.deferred_source_apply = .{
        .cycle_id = failure_cycle,
        .finished = .{
            .identity = app_page.RequestIdentity.review(0, 1),
            .generation = 3,
            .result = .{ .failed = try allocator.dupe(u8, "owned deferred failure") },
        },
    };
    var failure_applied = (try accepted_controller.applyDeferredSource(allocator, false)) orelse return error.ExpectedDeferredApply;
    defer failure_applied.deinit(allocator);
    try std.testing.expect(failure_applied.owned_failure_message != null);
    try std.testing.expectEqualStrings("owned deferred failure", failure_applied.source.auto_reload_failure.?.message);
}
