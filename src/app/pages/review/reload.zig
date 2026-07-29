//! Review-local reload, projection identity, and navigation-restore ownership.
//!
//! Async task allocation/spawn remains a shell effect during Phase 9 A3. This
//! module owns the page state transitions which prepare and reconcile those
//! effects; it deliberately has no `App`, `Ctx`, overlay, or process access.

const std = @import("std");
const context = @import("../../../context.zig");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const builtin = @import("builtin");
const auto_reload = @import("../../auto_reload.zig");
const app_actions = @import("../../actions.zig");
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const load_state = @import("../../load_state.zig");
const projection_component = @import("../../projection_component.zig");
const review_projection = @import("../../review_projection.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");
const review_page = @import("../review.zig");
const ReviewRepositoryReadEpoch = review_page.repository_read_authority.ReviewRepositoryReadEpoch;
const review_selection = @import("selection.zig");
const session_hunk_mark = @import("session_hunk_mark.zig");
const review_operations = if (builtin.is_test) @import("operations.zig") else struct {};
const file_search = @import("file_search.zig");
const authority = @import("authority.zig");
const navigation = @import("navigation.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_hunk_projection = @import("../../../diff/hunk_projection.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_presentation_identity = @import("../../../diff/presentation_identity.zig");
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
    /// True only when the delivered terminal owned the exact pending read and
    /// passed the current repository epoch/phase and background-cycle fence.
    /// App uses this to keep rejected reads from consuming action authority.
    terminal_admitted: bool = false,
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
    /// The task result moved into retained or deferred page ownership.
    result_transferred: bool = false,
    /// No visible, diagnostic, or navigation state changed.
    skip_redraw: bool = false,
};

pub const GeneratedSyntaxApply = struct {
    skip_redraw: bool = false,
};

pub const RedrawDisposition = enum {
    normal,
    skip,
    skip_unless_recovered_failure_cleared,
};

const StatusProjectionOutcome = enum {
    /// The active sidebar corresponds to the accepted source/status model.
    current_sidebar,
    /// An action refresh intentionally retains an older intermediate tree.
    deferred_sidebar,
};

fn cloneSidebarIdentity(
    allocator: std.mem.Allocator,
    identity: context.SidebarIdentity,
) !context.SidebarIdentity {
    return switch (identity) {
        .repo_root => .repo_root,
        .directory => |path| .{ .directory = try allocator.dupe(u8, path) },
        .file => |path_key| .{ .file = try allocator.dupe(u8, path_key) },
    };
}

pub const StatusProjectionTrigger = enum {
    /// A newly accepted source already materialized the empty-status tree; the
    /// projection step only needs to merge a non-empty retained status.
    accepted_source,
    /// A newly accepted status may remove the last status-only rows, so even
    /// an empty document is an authoritative sidebar replacement.
    accepted_status,
    /// The exact action source/status pair is terminal. Reconcile both
    /// accepted members before the action cursor owner is consumed.
    terminal_action,
};

pub const SourceApply = struct {
    result_transferred: bool = false,
    recovered_failure: ?auto_reload.FailureIdentity = null,
    auto_reload_failure: ?struct {
        identity: auto_reload.FailureIdentity,
        message: []const u8,
    } = null,
    redraw: RedrawDisposition = .normal,
    /// See `CompletionApply.terminal_admitted`.
    terminal_admitted: bool = false,
};

const PreparedCanonicalSource = union(enum) {
    unchanged,
    empty,
    loaded: load_state.LoadedSession,

    fn deinit(self: *PreparedCanonicalSource, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*session| session.deinit(allocator),
            .unchanged, .empty => {},
        }
        self.* = .unchanged;
    }
};

const PreparedCanonicalCurrentTree = struct {
    tree: file_tree.FileTree,
    visible_nodes: []usize,
    visible_node_count: usize,
    root_disclosure: file_tree.RootDisclosure,
    previous_path_key: ?[]const u8,
    previous_sidebar_identity: ?context.SidebarIdentity,
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

const OwnedCombinedPresentationKind = enum {
    combined,
    retained_staged_only,
};

/// Borrowed view of the self-owned A-to-C presentation which may survive an
/// index-only authority transition. The tag keeps the same-kind P4 refresh
/// distinct from P5c's staged-only-to-combined boundary even though both
/// states intentionally share `CombinedPresentation` ownership.
const OwnedCombinedPresentation = struct {
    kind: OwnedCombinedPresentationKind,
    presentation: *const review_projection.CombinedPresentation,
    display_file: diff_parser.FileDiff,
};

/// Exact P5d handoff between the disappearing combined projection and the
/// already-owned ordinary primary presentation. Both tokens are scalar: no
/// pointer into either display owner survives projection teardown.
const CombinedToOrdinaryOwner = enum {
    self_owned,
    primary_backed,
};

/// One visible Review presentation lineage scoped to the repository/path
/// whose display ordinals it names. The slices remain borrowed from live page
/// or request ownership; only the scalar content token crosses transitions.
const PresentationLineage = struct {
    repo_root: []const u8,
    path_key: []const u8,
    content: review_selection.ReviewContentToken,
};

/// Exact proof that display ordinals keep their meaning across an owner or
/// token-namespace transition. Status/component revisions are deliberately
/// absent: they authorize actions, not presentation-coordinate transfer.
const PresentationLineageTransfer = struct {
    repo_root: []const u8,
    path_key: []const u8,
    from: review_selection.ReviewContentToken,
    to: review_selection.ReviewContentToken,
};

/// The projection lifecycle is local to one repository path. Keeping this
/// scope distinct from a source-session or repository invalidation prevents a
/// completion for file B from consuming an owned selection captured in file A.
const ProjectionSelectionScope = struct {
    repo_root: []const u8,
    path_key: []const u8,
};

const CombinedToOrdinaryBoundary = struct {
    owner: CombinedToOrdinaryOwner,
    transfer: PresentationLineageTransfer,
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
    read_epoch: ReviewRepositoryReadEpoch,
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
    read_epoch: ReviewRepositoryReadEpoch,
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
    read_epoch: ReviewRepositoryReadEpoch,
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
        const sidebar_identity = self.navigation.selectedSidebarIdentity() orelse return null;
        const selected_target = self.page.viewer.selected_target orelse return null;
        const visible_row = loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0;

        const owned_path_key = try allocator.dupe(u8, path_key);
        errdefer allocator.free(owned_path_key);
        const owned_sidebar_identity = try cloneSidebarIdentity(allocator, sidebar_identity);

        return .{
            .path_key = owned_path_key,
            .sidebar_identity = owned_sidebar_identity,
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

    /// P5b only crosses an already-materialized combined presentation into a
    /// staged-only authority generation. Fresh status alone is insufficient:
    /// an ordinary primary body has no combined owner/token to reuse and must
    /// keep its existing status-only session path instead of starting an
    /// eager cached projection.
    fn hasCombinedBoundaryOwner(self: View, path_key: []const u8) bool {
        return switch (self.navigation.displayedReviewBody()) {
            .combined => |bundle| if (diff_file.canonicalPathKey(bundle.displayFile())) |display_path|
                std.mem.eql(u8, display_path, path_key)
            else
                false,
            .primary => |primary| blk: {
                const hunk_authority = primary.hunk_authority orelse break :blk false;
                if (hunk_authority != .combined) break :blk false;
                const display_path = diff_file.canonicalPathKey(
                    primary.loaded.document.files[primary.file_index],
                ) orelse break :blk false;
                break :blk std.mem.eql(u8, display_path, path_key);
            },
            else => false,
        };
    }

    pub fn projectionTarget(self: View) ?ProjectionTarget {
        const repo_root = self.repo_root orelse return null;
        const projection_source = sourceKind(self.source);

        if (self.navigation.selectedFile()) |file| {
            const path_key = diff_file.canonicalPathKey(file) orelse return null;
            const entry = self.navigation.freshStatusEntryForPathKey(repo_root, path_key) orelse return null;
            if (sourceIsUnstaged(self.source)) {
                if (isCombinedHunkProjectionCandidate(file, entry)) {
                    return .{
                        .repo_root = repo_root,
                        .path_key = path_key,
                        .kind = .combined_hunks,
                        .source_kind = projection_source,
                    };
                }
                // The final unstaged hunk can leave the watched primary file
                // selected until a later source reload removes it. Publish the
                // staged-only target from fresh status immediately so P5b can
                // compare against the still-owned presentation and preserve
                // the exact path/cursor instead of waiting for ordinal remap.
                if (file_tree.stagePresenceFromEntry(entry) == .staged_only and
                    self.hasCombinedBoundaryOwner(path_key))
                {
                    return .{
                        .repo_root = repo_root,
                        .path_key = path_key,
                        .kind = .cached_diff,
                        .source_kind = projection_source,
                    };
                }
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

    /// Snapshot publication authority before draining a background member.
    /// The final member removes its cycle, so checking after `finishMember`
    /// would incorrectly reject a valid exact terminal.
    fn acceptsRepositoryReadCompletion(
        self: Controller,
        read_epoch: ReviewRepositoryReadEpoch,
        background_cycle_id: ?u64,
    ) bool {
        return self.page.repository_read_authority.acceptsRead(read_epoch) and
            self.page.auto_reload.acceptsCycle(background_cycle_id);
    }

    /// Every source/status/branch preparation crosses this page-owned gate.
    /// App scheduling normally waits before calling a prepare method, while
    /// this boundary prevents a future direct caller from creating a
    /// current-epoch read during an accepted repository mutation.
    fn requireRepositoryReadStart(self: Controller) error{RepositoryReadAuthorityClosed}!void {
        if (!self.page.repository_read_authority.mayStartRepositoryRead()) {
            return error.RepositoryReadAuthorityClosed;
        }
    }

    /// Atomically closes Review repository-read authority for one accepted
    /// mutating action and retires projection work derived before that action.
    ///
    /// The displayed body and cache remain owned so launch itself cannot blank
    /// or flicker the UI. Their old epoch prevents promotion or write
    /// authority. Source, status, and branch task owners also remain intact so
    /// their terminals can perform exact tracker and background-cycle drain.
    pub fn beginMutationReadFence(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
    ) bool {
        if (!self.page.repository_read_authority.closeForMutation(pending)) return false;

        self.page.auto_reload.supersedeActiveCycleByMutation();
        self.page.review_projection.clearPending(allocator);
        self.page.review_projection.clearSyntaxPending(allocator);
        if (self.page.deferred_projection_apply) |*deferred| deferred.deinit(allocator);
        self.page.deferred_projection_apply = null;
        return true;
    }

    /// Reopens the Review repository-read authority for its exact mutating
    /// action terminal, then coalesces one foreground revalidation intent for
    /// the activation which observed that terminal.
    ///
    /// Reopening must happen before queueing: the post-update scheduler may
    /// consume this intent immediately, and every successor read must capture
    /// the already-advanced open epoch. An inactive page still releases the
    /// gate, but the activation-scoped terminal fallback deliberately does not
    /// target a future activation. Stale, mismatched, and duplicate terminals
    /// change neither owner.
    pub fn finishMutationReadFence(
        self: Controller,
        pending: app_actions.PendingAction,
    ) bool {
        if (!self.page.repository_read_authority.reopenForMutation(pending)) return false;
        self.page.activation.queueActionTerminalRevalidation();
        return true;
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

    /// Projection replacement never invalidates another path. Global owner
    /// boundaries use `clearCompletedSelection` directly instead.
    fn clearCompletedSelectionForProjection(
        self: Controller,
        allocator: std.mem.Allocator,
        scope: ProjectionSelectionScope,
    ) void {
        const active_root = self.repo_root orelse return;
        if (!std.mem.eql(u8, active_root, scope.repo_root)) return;
        const completed = self.page.completed_selection orelse return;
        if (!std.mem.eql(u8, completed.pathKey(), scope.path_key)) return;
        self.clearCompletedSelection(allocator);
    }

    fn ownedCombinedPresentation(self: Controller) ?OwnedCombinedPresentation {
        return switch (self.navigation.view().displayedReviewBody()) {
            .combined => |bundle| .{
                .kind = .combined,
                .presentation = &bundle.presentation,
                .display_file = bundle.displayFile(),
            },
            .retained_staged_only => |bundle| .{
                .kind = .retained_staged_only,
                .presentation = &bundle.presentation,
                .display_file = bundle.displayFile(),
            },
            else => null,
        };
    }

    /// Status acceptance immediately invalidates status-derived projection
    /// candidates except for combined content. A combined candidate remains
    /// valid against the still-live presentation while fresh authority is
    /// pending; exact presentation acceptance later transfers its token or
    /// clears it. This does not keep old hunk action authority fresh.
    fn clearStatusInvalidatedCompletedSelection(self: Controller, allocator: std.mem.Allocator) void {
        const completed = self.page.completed_selection orelse return;
        switch (completed.token.display) {
            .loaded, .combined_projection => {},
            .cached_projection, .generated_untracked => self.clearCompletedSelection(allocator),
        }
    }

    fn contentTokenForReady(self: Controller, ready: *const review_projection.Ready) ?review_selection.ReviewContentToken {
        const display: review_selection.DisplayBasis = switch (ready.*) {
            .cached_diff => |bundle| .{ .cached_projection = .{
                .status_snapshot_revision = self.page.status_snapshot_revision,
                .cached = bundle.fingerprint,
            } },
            .combined_hunks => |bundle| .{ .combined_projection = bundle.presentation.content_token },
            .primary_combined_authority => blk: {
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |primary| primary,
                    else => return null,
                };
                break :blk .{ .loaded = .init(primary.loaded.text) };
            },
            .retained_staged_only => |bundle| .{ .combined_projection = bundle.presentation.content_token },
            .primary_staged_only_authority => blk: {
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |primary| primary,
                    else => return null,
                };
                break :blk .{ .loaded = .init(primary.loaded.text) };
            },
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

    fn currentPresentationLineageForPath(
        self: Controller,
        repo_root: []const u8,
        path_key: []const u8,
    ) ?PresentationLineage {
        const active_root = self.repo_root orelse return null;
        if (!std.mem.eql(u8, active_root, repo_root)) return null;
        const file = self.navigation.view().displayedDiffFile() orelse return null;
        const displayed_path = diff_file.canonicalPathKey(file) orelse return null;
        if (!std.mem.eql(u8, displayed_path, path_key)) return null;
        return .{
            .repo_root = repo_root,
            .path_key = path_key,
            .content = self.navigation.view().currentContentToken() orelse return null,
        };
    }

    /// Return a lineage only when the visible text is owned by the projection
    /// which is about to be replaced. Primary-backed authority overlays use
    /// the independently owned loaded token and therefore need no clear when
    /// the overlay alone disappears.
    fn currentOwnedProjectionLineage(self: Controller) ?PresentationLineage {
        switch (self.navigation.view().displayedReviewBody()) {
            .cached, .combined, .retained_staged_only => {},
            .primary, .none, .generated, .inert_invalid_utf8, .status, .pending => return null,
        }
        const repo_root = self.repo_root orelse return null;
        const file = self.navigation.view().displayedDiffFile() orelse return null;
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        return self.currentPresentationLineageForPath(repo_root, path_key);
    }

    /// Apply an already-proved presentation transfer to every Review-local
    /// consumer of display ordinals. No Git/action authority is changed here.
    fn applyPresentationLineageTransfer(
        self: Controller,
        allocator: std.mem.Allocator,
        transfer: PresentationLineageTransfer,
    ) void {
        if (self.page.completed_selection) |*completed| {
            if (self.repo_root) |active_root| {
                if (std.mem.eql(u8, active_root, transfer.repo_root) and
                    std.mem.eql(u8, completed.pathKey(), transfer.path_key))
                {
                    if (completed.token.eql(transfer.from)) {
                        completed.token = transfer.to;
                    } else if (!completed.token.eql(transfer.to)) {
                        self.clearCompletedSelectionForProjection(allocator, .{
                            .repo_root = transfer.repo_root,
                            .path_key = transfer.path_key,
                        });
                    }
                }
            }
        }
        self.page.staged_hunks.rebindPathLineage(
            allocator,
            transfer.repo_root,
            transfer.path_key,
            transfer.from,
            transfer.to,
        );
    }

    /// Invalidate only ordinals owned by the outgoing path lineage. Marks for
    /// another path or an older/newer token remain independently meaningful.
    fn clearPresentationLineage(
        self: Controller,
        allocator: std.mem.Allocator,
        lineage: PresentationLineage,
    ) void {
        if (self.page.completed_selection) |completed| {
            if (completed.token.eql(lineage.content)) {
                self.clearCompletedSelectionForProjection(allocator, .{
                    .repo_root = lineage.repo_root,
                    .path_key = lineage.path_key,
                });
            }
        }
        self.page.staged_hunks.clearPathLineage(
            allocator,
            lineage.repo_root,
            lineage.path_key,
            lineage.content,
        );
    }

    /// Complete an exact owner transition after its install. Exact comparison
    /// is performed by the caller; this helper only materializes its typed
    /// consequence, including a future token-namespace change.
    fn finishExactPresentationTransfer(
        self: Controller,
        allocator: std.mem.Allocator,
        outgoing: ?PresentationLineage,
    ) void {
        const from = outgoing orelse return;
        const incoming = self.currentPresentationLineageForPath(from.repo_root, from.path_key) orelse {
            self.clearPresentationLineage(allocator, from);
            return;
        };
        self.applyPresentationLineageTransfer(allocator, .{
            .repo_root = from.repo_root,
            .path_key = from.path_key,
            .from = from.content,
            .to = incoming.content,
        });
    }

    /// Resolve the final-staged-hunk unstage boundary without manufacturing a
    /// new projection. The primary load is an independent owner which predates
    /// the combined overlay; exact presentation equality is nevertheless
    /// required before a completed selection may cross from the projection
    /// token namespace into the loaded token namespace.
    fn combinedToOrdinaryBoundary(self: Controller) ?CombinedToOrdinaryBoundary {
        if (!sourceIsUnstaged(self.source)) return null;
        const repo_root = self.repo_root orelse return null;
        const loaded = self.navigation.view().activeLoadedDiffConst() orelse return null;
        const file_index = self.navigation.view().selectedFileIndex(loaded) orelse return null;
        if (file_index >= loaded.document.files.len) return null;
        const primary_file = loaded.document.files[file_index];
        const path_key = diff_file.canonicalPathKey(primary_file) orelse return null;
        const entry = self.navigation.view().freshStatusEntryForPathKey(repo_root, path_key) orelse return null;
        if (file_tree.stagePresenceFromEntry(entry) != .unstaged_only) return null;

        const ready = switch (self.page.review_projection.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => return null,
        };
        if (!ready.request.matchesDisplayIdentity(
            repo_root,
            path_key,
            sourceKind(self.source),
            self.page.source_session_revision,
        )) return null;

        var owner: CombinedToOrdinaryOwner = undefined;
        const combined_file = switch (ready.value) {
            .combined_hunks => |*bundle| blk: {
                owner = .self_owned;
                break :blk bundle.displayFile();
            },
            // This overlay owns only fresh index authority. Its visible file
            // is already the independently owned primary file.
            .primary_combined_authority => blk: {
                owner = .primary_backed;
                break :blk primary_file;
            },
            else => return null,
        };
        if (!diff_presentation_identity.exactEqual(combined_file, primary_file)) return null;

        const displayed_content = self.contentTokenForReady(&ready.value) orelse return null;
        const ordinary_content: review_selection.ReviewContentToken = .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = review_selection.SourceBasis.init(self.source),
            .source_session_revision = self.page.source_session_revision,
            .display = .{ .loaded = .init(loaded.text) },
        };
        return .{
            .owner = owner,
            .transfer = .{
                .repo_root = repo_root,
                .path_key = path_key,
                .from = displayed_content,
                .to = ordinary_content,
            },
        };
    }

    /// Preserve semantic selection identity across an eager combined rebuild
    /// only when the still-live and incoming presentations are exactly equal.
    /// The fingerprint is a cheap candidate hint; it never authorizes token
    /// transfer by itself. Fresh status/component identity remains attached to
    /// the incoming authority and is intentionally untouched here.
    fn retainCombinedPresentationTokenIfExact(
        self: Controller,
        repo_root: []const u8,
        path_key: []const u8,
        ready: *review_projection.Ready,
    ) ?PresentationLineageTransfer {
        const outgoing = self.currentPresentationLineageForPath(repo_root, path_key) orelse return null;
        const incoming = switch (ready.*) {
            .combined_hunks => |*bundle| bundle,
            else => return null,
        };
        const live = self.navigation.view().activeCombinedProjection() orelse return null;
        if (!live.presentation.fingerprint.eql(incoming.presentation.fingerprint)) return null;
        if (!diff_presentation_identity.exactEqual(live.displayFile(), incoming.displayFile())) return null;
        incoming.presentation.content_token = live.presentation.content_token;
        const incoming_content = self.contentTokenForReady(ready) orelse return null;
        return .{
            .repo_root = repo_root,
            .path_key = path_key,
            .from = outgoing.content,
            .to = incoming_content,
        };
    }

    /// Snapshot only scalar presentation identity into a same-kind refresh.
    /// Request/status authority remains independently fresh; no page-owned
    /// pointer or slice crosses into the worker task.
    fn expectedPresentationForTarget(
        self: Controller,
        target: ProjectionTarget,
    ) ?review_projection.ExpectedPresentation {
        switch (target.kind) {
            .combined_hunks, .cached_diff => {},
            .generated_added_file => return null,
        }
        if (self.ownedCombinedPresentation()) |live| {
            // A retained staged-only body feeds only P5c's return to combined;
            // an unchanged staged-only refresh remains on the existing eager
            // cached-diff path. The ordinary combined owner also serves P4's
            // same-kind refresh and P5b's final-hunk stage boundary.
            if (live.kind == .retained_staged_only and target.kind != .combined_hunks) return null;
            return .{
                .owner = .combined_projection,
                .fingerprint = live.presentation.fingerprint,
                .content_token = live.presentation.content_token,
            };
        }

        const primary = switch (self.navigation.view().displayedReviewBody()) {
            .primary => |primary| primary,
            else => return null,
        };
        switch (target.kind) {
            .combined_hunks => if (primary.hunk_authority) |hunk_authority| switch (hunk_authority) {
                .combined, .staged_only => {},
            },
            .cached_diff => {
                const hunk_authority = primary.hunk_authority orelse return null;
                if (hunk_authority != .combined) return null;
            },
            .generated_added_file => unreachable,
        }
        const file = primary.loaded.document.files[primary.file_index];
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        if (!std.mem.eql(u8, path_key, target.path_key)) return null;
        return .{
            .owner = .primary_loaded,
            .fingerprint = diff_presentation_identity.fingerprint(file),
            .content_token = .init(self.page.source_session_revision),
        };
    }

    /// Candidate fingerprints are only a worker hint. Fresh authority may be
    /// installed only while the request's expected token still names the live
    /// presentation and the allocation-free canonical comparator proves the
    /// normalized candidate exactly equal.
    fn acceptsCombinedReuseCandidate(
        self: Controller,
        request: review_projection.Request,
        candidate: *const review_projection.CombinedReuseCandidate,
    ) bool {
        const expected = request.expected_presentation orelse return false;
        if (!candidate.fingerprint.eql(expected.fingerprint)) return false;

        const fresh_authority = if (candidate.fresh_authority) |*fresh| fresh else return false;
        if (fresh_authority.status_snapshot_revision != request.status_snapshot_revision) return false;
        if (fresh_authority.cached_component.document.files.len != 1) return false;
        const candidate_hunks = candidate.displayFile().hunks.len;
        if (fresh_authority.projection.hunk_stage_states.len != candidate_hunks or
            fresh_authority.projection.hunk_action_origins.len != candidate_hunks) return false;

        return switch (expected.owner) {
            .combined_projection => blk: {
                const live = self.ownedCombinedPresentation() orelse break :blk false;
                if (!live.presentation.content_token.eql(expected.content_token)) break :blk false;
                if (!live.presentation.fingerprint.eql(expected.fingerprint)) break :blk false;
                break :blk diff_presentation_identity.exactEqual(live.display_file, candidate.displayFile());
            },
            .primary_loaded => blk: {
                const target = self.view().projectionTarget() orelse break :blk false;
                const live = self.expectedPresentationForTarget(target) orelse break :blk false;
                if (!live.eql(expected) or live.owner != .primary_loaded) break :blk false;
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |primary| primary,
                    else => break :blk false,
                };
                break :blk diff_presentation_identity.exactEqual(
                    primary.loaded.document.files[primary.file_index],
                    candidate.displayFile(),
                );
            },
        };
    }

    fn applyCombinedReuseCandidate(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) ProjectionApply {
        const candidate = &result.result.reuse_candidate;
        if (!self.acceptsCombinedReuseCandidate(result.request, candidate)) {
            self.rejectPresentationReuseCandidate(allocator);
            return .{};
        }

        const outgoing_lineage = self.currentPresentationLineageForPath(
            result.request.repo_root,
            result.request.path_key,
        );

        // Exact acceptance has proved one immutable presentation, but the
        // install operation must still consume the correct authority owner.
        // Record the P5c boundary before moving either request or payload.
        const returns_from_staged_only = switch (result.request.expected_presentation.?.owner) {
            .combined_projection => self.ownedCombinedPresentation().?.kind == .retained_staged_only,
            .primary_loaded => switch (self.navigation.view().displayedReviewBody()) {
                .primary => |primary| if (primary.hunk_authority) |hunk_authority|
                    hunk_authority == .staged_only
                else
                    false,
                else => false,
            },
        };

        self.page.review_projection.finishEagerRetry();
        self.page.review_projection.clearPending(allocator);
        const request = result.request;
        result.request = undefined;
        switch (request.expected_presentation.?.owner) {
            .combined_projection => if (returns_from_staged_only)
                self.page.review_projection.installCombinedFromRetainedStagedOnlyReuse(allocator, request, candidate)
            else
                self.page.review_projection.installCombinedReuse(allocator, request, candidate),
            .primary_loaded => self.page.review_projection.installPrimaryCombinedReuse(allocator, request, candidate),
        }
        candidate.deinit();
        result.result = undefined;
        self.finishExactPresentationTransfer(allocator, outgoing_lineage);
        if (returns_from_staged_only) {
            self.reconcileRetainedPresentationNavigation(allocator);
        } else {
            self.reconcileInstalledProjectionNavigation(allocator, null);
        }
        return .{ .result_transferred = true };
    }

    fn acceptsStagedOnlyReuseCandidate(
        self: Controller,
        request: review_projection.Request,
        candidate: *const review_projection.StagedOnlyReuseCandidate,
    ) bool {
        if (request.kind != .cached_diff) return false;
        const expected = request.expected_presentation orelse return false;
        if (!candidate.fingerprint.eql(expected.fingerprint)) return false;

        const fresh_authority = if (candidate.fresh_authority) |*fresh| fresh else return false;
        if (fresh_authority.status_snapshot_revision != request.status_snapshot_revision) return false;
        // Task construction promises exactly one cached file, but task result
        // payloads still cross an ownership/admission boundary. Validate the
        // shape before displayFile() performs its invariant-based index.
        if (fresh_authority.cached_component.document.files.len != 1) return false;
        const candidate_hunks = candidate.displayFile().hunks.len;
        if (fresh_authority.projection.hunk_stage_states.len != candidate_hunks or
            fresh_authority.projection.hunk_action_origins.len != candidate_hunks) return false;
        for (fresh_authority.projection.hunk_stage_states, fresh_authority.projection.hunk_action_origins, 0..) |state, origin, hunk_index| {
            if (state != .staged) return false;
            switch (origin) {
                .cached => |index| if (index != hunk_index) return false,
                .unstaged => return false,
            }
        }

        const target = self.view().projectionTarget() orelse return false;
        const live = self.expectedPresentationForTarget(target) orelse return false;
        if (!live.eql(expected)) return false;
        return switch (expected.owner) {
            .combined_projection => blk: {
                const projection = self.navigation.view().activeCombinedProjection() orelse break :blk false;
                break :blk diff_presentation_identity.exactEqual(projection.displayFile(), candidate.displayFile());
            },
            .primary_loaded => blk: {
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |primary| primary,
                    else => break :blk false,
                };
                break :blk diff_presentation_identity.exactEqual(
                    primary.loaded.document.files[primary.file_index],
                    candidate.displayFile(),
                );
            },
        };
    }

    fn rejectPresentationReuseCandidate(self: Controller, allocator: std.mem.Allocator) void {
        // Preserve only scalar display identity so the same live body gets one
        // hint-free eager retry. A target/owner change consumes the marker.
        if (self.view().projectionTarget()) |target| {
            if (self.expectedPresentationForTarget(target)) |live| {
                self.page.review_projection.scheduleEagerRetry(live);
            } else {
                self.page.review_projection.finishEagerRetry();
            }
        } else {
            self.page.review_projection.finishEagerRetry();
        }
        self.page.review_projection.clearPending(allocator);
    }

    fn applyStagedOnlyReuseCandidate(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) ProjectionApply {
        const candidate = &result.result.staged_only_reuse_candidate;
        if (!self.acceptsStagedOnlyReuseCandidate(result.request, candidate)) {
            self.rejectPresentationReuseCandidate(allocator);
            return .{};
        }

        const outgoing_lineage = self.currentPresentationLineageForPath(
            result.request.repo_root,
            result.request.path_key,
        );

        self.page.review_projection.finishEagerRetry();
        self.page.review_projection.clearPending(allocator);
        const request = result.request;
        result.request = undefined;
        switch (request.expected_presentation.?.owner) {
            .combined_projection => self.page.review_projection.installRetainedStagedOnlyReuse(allocator, request, candidate),
            .primary_loaded => self.page.review_projection.installPrimaryStagedOnlyReuse(allocator, request, candidate),
        }
        candidate.deinit();
        result.result = undefined;
        self.finishExactPresentationTransfer(allocator, outgoing_lineage);
        self.reconcileRetainedPresentationNavigation(allocator);
        return .{ .result_transferred = true };
    }

    /// A candidate is meaningful only for the exact semantic display basis it
    /// captured. Delivery IDs, status revisions, component fingerprints, and
    /// cache slots are intentionally absent from combined display identity.
    /// Exact acceptance above transfers the live presentation token before
    /// this check; changed content is cleared before the old owner is moved or
    /// freed.
    fn reconcileCompletedSelectionForReady(
        self: Controller,
        allocator: std.mem.Allocator,
        scope: ProjectionSelectionScope,
        ready: *const review_projection.Ready,
    ) void {
        const completed = self.page.completed_selection orelse return;
        const active_root = self.repo_root orelse return;
        if (!std.mem.eql(u8, active_root, scope.repo_root) or
            !std.mem.eql(u8, completed.pathKey(), scope.path_key)) return;
        const incoming = self.contentTokenForReady(ready) orelse {
            self.clearCompletedSelectionForProjection(allocator, scope);
            return;
        };
        if (!completed.token.eql(incoming)) self.clearCompletedSelectionForProjection(allocator, scope);
    }

    /// A normal loaded diff intentionally has no projection target. Reaching
    /// that steady state must not erase an owned candidate captured from the
    /// same loaded bytes; projection-derived candidates still become stale
    /// when their displayed projection disappears.
    fn reconcileCompletedSelectionForNoProjectionTarget(
        self: Controller,
        allocator: std.mem.Allocator,
    ) void {
        const repo_root = self.repo_root orelse return;
        const path_key = self.navigation.view().selectedStagePathKey() orelse return;
        const scope: ProjectionSelectionScope = .{ .repo_root = repo_root, .path_key = path_key };
        const completed = self.page.completed_selection orelse return;
        if (!std.mem.eql(u8, completed.pathKey(), path_key)) return;
        const primary = switch (self.navigation.view().displayedReviewBody()) {
            .primary => |primary| primary,
            else => {
                self.clearCompletedSelectionForProjection(allocator, scope);
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
        if (!completed.token.eql(current)) self.clearCompletedSelectionForProjection(allocator, scope);
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

    fn canonicalPublicationPath(
        self: Controller,
        repo_root: []const u8,
        options: SourceLoadOptions,
    ) ?[]const u8 {
        if (options.clear_visible_state) return null;
        switch (options.kind) {
            .watch, .action_result => {},
            .initial, .manual, .repo_switch => return null,
        }
        if (!diff_source.sourceAllowsStageProjection(self.source)) return null;
        const basis_path = blk: {
            if (self.page.review_projection.displayed.request()) |displayed| {
                if (std.mem.eql(u8, displayed.repo_root, repo_root) and
                    displayed.source_kind == sourceKind(self.source))
                {
                    break :blk displayed.path_key;
                }
            }
            if (!sourceIsUnstaged(self.source)) return null;
            const active_root = self.repo_root orelse return null;
            if (!std.mem.eql(u8, active_root, repo_root)) return null;
            const primary = switch (self.navigation.view().displayedReviewBody()) {
                .primary => |value| value,
                else => return null,
            };
            const file = primary.loaded.document.files[primary.file_index];
            const path_key = diff_file.canonicalPathKey(file) orelse return null;
            if (path_key.len == 0) return null;
            break :blk path_key;
        };
        if (self.page.action_cursor.target()) |target| {
            if (target.kind == .file and target.path_key.len > 0) return target.path_key;
        }
        return self.navigation.view().selectedStagePathKey() orelse basis_path;
    }

    fn beginCanonicalPublication(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: ?[]const u8,
        options: SourceLoadOptions,
        identity: app_page.RequestIdentity,
        generation: u64,
    ) !void {
        const root = repo_root orelse return;
        const path_key = self.canonicalPublicationPath(root, options) orelse return;
        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const owned_path = try allocator.dupe(u8, path_key);
        self.page.canonical_publication = .{
            .identity = identity,
            .read_epoch = self.page.repository_read_authority.epoch,
            .source_generation = generation,
            .kind = options.kind,
            .repo_root = owned_root,
            .path_key = owned_path,
        };
    }

    fn canonicalGateMatchesSource(
        self: Controller,
        finished: *const app_load.DiffLoadFinished,
    ) bool {
        const gate = self.page.canonical_publication orelse return false;
        return gate.phase == .waiting_members and
            gate.source_generation == finished.generation and
            gate.identity.origin == finished.identity.origin and
            gate.identity.repo_epoch == finished.identity.repo_epoch and
            gate.identity.activation_id == finished.identity.activation_id and
            gate.read_epoch.eql(finished.read_epoch);
    }

    fn canonicalGateMatchesStatus(
        self: Controller,
        result: *const app_load.StatusLoadFinished,
    ) bool {
        const gate = self.page.canonical_publication orelse return false;
        const generation = gate.status_generation orelse return false;
        return gate.phase == .waiting_members and
            generation == result.generation and
            gate.identity.origin == result.identity.origin and
            gate.identity.repo_epoch == result.identity.repo_epoch and
            gate.identity.activation_id == result.identity.activation_id and
            gate.status_read_epoch.eql(result.read_epoch) and
            std.mem.eql(u8, gate.repo_root, result.repo_root);
    }

    fn refreshCanonicalPath(
        self: Controller,
        allocator: std.mem.Allocator,
        gate: anytype,
    ) !bool {
        const selected = self.navigation.view().selectedStagePathKey() orelse return false;
        if (selected.len == 0 or std.mem.eql(u8, selected, gate.path_key)) return false;
        const owned = try allocator.dupe(u8, selected);
        allocator.free(gate.path_key);
        gate.path_key = owned;
        return true;
    }

    fn abortCanonicalPublication(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page.canonical_publication == null) return;
        self.page.canonical_publication.?.phase = .aborting;
        const gate_identity = self.page.canonical_publication.?.identity;
        const source_generation = self.page.canonical_publication.?.source_generation;
        const projection_request_id = self.page.canonical_publication.?.projection_request_id;
        if (self.page.canonical_publication.?.status_generation) |status_generation| {
            if (self.page.status_load.pending) |pending| {
                if (pending.generation == status_generation and
                    pending.read_epoch.eql(self.page.canonical_publication.?.status_read_epoch) and
                    pending.background_cycle_id == self.page.canonical_publication.?.status_background_cycle_id)
                {
                    self.page.canonical_status_drain = .{
                        .generation = status_generation,
                        .read_epoch = pending.read_epoch,
                        .background_cycle_id = pending.background_cycle_id,
                    };
                }
            }
        }

        if (projection_request_id) |request_id| {
            if (self.page.deferred_projection_apply) |*deferred| {
                if (deferred.finished.request.id == request_id) {
                    deferred.deinit(allocator);
                    self.page.deferred_projection_apply = null;
                }
            }
            if (self.page.review_projection.pending) |pending| {
                if (pending.id == request_id) self.page.review_projection.clearPending(allocator);
            }
        }

        if (self.page.deferred_source_apply) |deferred| {
            if (deferred.mode == .canonical_publication and
                deferred.finished.generation == source_generation)
            {
                var owned = deferred;
                self.page.deferred_source_apply = null;
                if (self.takeOwnedSourceTerminal(&owned.finished)) |pending_value| {
                    var pending = pending_value;
                    pending.deinit(allocator);
                }
                if (owned.cycle_id != 0) {
                    self.page.auto_reload.finishMember(owned.cycle_id, .deferred_source_apply);
                }
                owned.deinit(allocator);
            }
        } else {
            _ = self.page.load.clearPendingIfCurrent(.{ .diff_load = source_generation });
            self.clearPendingReloadIfGeneration(allocator, source_generation);
        }

        self.navigation.clearActionCursor(allocator);
        _ = self.page.activation.finishMember(gate_identity, .source, .failed);
        _ = self.page.activation.finishMember(gate_identity, .status, .failed);
        var gate = self.page.canonical_publication.?;
        self.page.canonical_publication = null;
        gate.deinit(allocator);
    }

    pub fn beginPendingReload(self: Controller, allocator: std.mem.Allocator, generation: u64, kind: review_page.ReloadKind) !void {
        self.clearPendingReload(allocator);
        const anchor = switch (kind) {
            .manual, .watch => try self.view().captureAnchor(allocator),
            .initial, .action_result, .repo_switch => null,
        };
        errdefer if (anchor) |*captured| captured.deinit(allocator);
        self.page.pending_reload = .{
            .generation = generation,
            .read_epoch = self.page.repository_read_authority.epoch,
            .kind = kind,
            .anchor = anchor,
        };
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

    fn sourceTerminalOwnsPending(self: Controller, finished: *const app_load.DiffLoadFinished) bool {
        if (!self.page.load.isCurrent(finished.generation)) return false;
        const pending_load = self.page.load.pending orelse return false;
        if (!std.meta.eql(pending_load, load_state.PendingLoad{ .diff_load = finished.generation })) return false;
        const pending_reload = self.page.pending_reload orelse return false;
        return pending_reload.matchesTerminal(finished.generation, finished.read_epoch);
    }

    /// Retire source ownership only for the exact generation/epoch terminal.
    /// Admission is intentionally separate: an old epoch still owns cleanup,
    /// but can no longer publish any Review state or shell consequence.
    fn takeOwnedSourceTerminal(
        self: Controller,
        finished: *const app_load.DiffLoadFinished,
    ) ?review_page.PendingReload {
        if (!self.sourceTerminalOwnsPending(finished)) return null;
        std.debug.assert(self.page.load.finishPending(.{ .diff_load = finished.generation }));
        const pending = self.page.pending_reload.?;
        self.page.pending_reload = null;
        return pending;
    }

    fn retireOwnedSourceTerminal(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: *const app_load.DiffLoadFinished,
    ) bool {
        var pending = self.takeOwnedSourceTerminal(finished) orelse return false;
        pending.deinit(allocator);
        return true;
    }

    pub fn clearPendingReloadIfGeneration(self: Controller, allocator: std.mem.Allocator, generation: u64) void {
        var pending = self.takePendingReloadIfGeneration(generation) orelse return;
        pending.deinit(allocator);
    }

    pub fn clearPendingReload(self: Controller, allocator: std.mem.Allocator) void {
        self.abortCanonicalPublication(allocator);
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
        const current = self.page.deferred_source_apply orelse return;
        if (current.mode == .canonical_publication) {
            self.abortCanonicalPublication(allocator);
            return;
        }
        var deferred = current;
        self.page.deferred_source_apply = null;
        _ = self.retireOwnedSourceTerminal(allocator, &deferred.finished);
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
        if (deferred.mode == .canonical_publication) return null;
        self.page.deferred_source_apply = null;
        const publication_admitted = deferred.finished.background_cycle_id == deferred.cycle_id and
            !background_blocked and
            self.acceptsIdentity(deferred.finished.identity) and
            self.acceptsRepositoryReadCompletion(deferred.finished.read_epoch, deferred.cycle_id);
        defer self.page.auto_reload.finishMember(deferred.cycle_id, .deferred_source_apply);

        var finished = deferred.finished;
        var result_transferred = false;
        defer if (!result_transferred) finished.deinit(allocator);

        if (!publication_admitted) {
            _ = self.retireOwnedSourceTerminal(allocator, &finished);
            return .{ .source = .{ .redraw = .skip } };
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
        try self.requireRepositoryReadStart();
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        self.abortCanonicalPublication(allocator);
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
        try self.beginCanonicalPublication(allocator, repo_root, options, identity, generation);
        errdefer if (self.page.canonical_publication) |gate| {
            if (gate.source_generation == generation) self.abortCanonicalPublication(allocator);
        };

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
            .read_epoch = self.page.repository_read_authority.epoch,
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
        try self.requireRepositoryReadStart();
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
        self.page.activation.consumeAcceptedFullRevalidation();
    }

    pub fn rejectRepoDiscoverySpawn(self: Controller, generation: u64) void {
        _ = self.page.load.clearPendingIfCurrent(.{ .repo_discovery = generation });
        if (!self.page.load.hasPending() and self.page.load.state == .loading) {
            self.page.load.state = .idle;
        }
        self.failActiveMember(.source);
    }

    pub fn acceptSourceSpawn(self: Controller, background_cycle_id: ?u64) void {
        if (background_cycle_id) |cycle_id| _ = self.page.auto_reload.markMemberStarted(cycle_id, .source);
        self.page.activation.consumeAcceptedFullRevalidation();
    }

    pub fn prepareStatusLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        origin: git_backend.ReadOrigin,
        background_cycle_id: ?u64,
    ) !ReviewUpdate {
        try self.requireRepositoryReadStart();
        const identity = self.page.activation.currentIdentity() orelse return error.InactiveReviewPage;
        const canonical_prerequisite = if (self.page.canonical_publication) |gate|
            gate.phase == .waiting_members and
                gate.read_epoch.eql(self.page.repository_read_authority.epoch) and
                std.mem.eql(u8, gate.repo_root, repo_root)
        else
            false;
        if (canonical_prerequisite) {
            self.invalidateStatusSnapshot();
        } else if (self.page.git_status.repo_root) |current_root| {
            if (std.mem.eql(u8, current_root, repo_root)) {
                self.invalidateStatusSnapshot();
            } else {
                self.dropStatusSnapshot(allocator);
            }
        } else {
            self.dropStatusSnapshot(allocator);
        }
        const owned_root = try allocator.dupe(u8, repo_root);
        self.page.status_load.begin(background_cycle_id, self.page.repository_read_authority.epoch);
        if (self.page.canonical_publication) |*gate| {
            if (gate.phase == .waiting_members and
                gate.read_epoch.eql(self.page.repository_read_authority.epoch) and
                std.mem.eql(u8, gate.repo_root, repo_root))
            {
                gate.status_generation = self.page.status_load.generation;
                gate.status_read_epoch = self.page.repository_read_authority.epoch;
                gate.status_background_cycle_id = background_cycle_id;
            }
        }
        self.page.activation.markPending(.status);
        return .{ .command = .{ .status_load = .{
            .identity = identity,
            .read_epoch = self.page.repository_read_authority.epoch,
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
        try self.requireRepositoryReadStart();
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
        self.page.branch_status_load.begin(background_cycle_id, self.page.repository_read_authority.epoch);
        self.page.activation.markPending(.branch);
        return .{ .command = .{ .branch_status_load = .{
            .identity = identity,
            .read_epoch = self.page.repository_read_authority.epoch,
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

    pub fn supersedeAcceptedStatusSpawn(
        self: Controller,
        terminal: auto_reload.AuxiliaryTerminal,
    ) bool {
        if (!self.page.status_load.supersedeTerminal(terminal)) return false;
        self.page.status_load.markFailure(self.page.git_status.repo_root != null);
        self.failActiveMember(.status);
        return true;
    }

    pub fn supersedeAcceptedBranchStatusSpawn(
        self: Controller,
        terminal: auto_reload.AuxiliaryTerminal,
    ) bool {
        if (!self.page.branch_status_load.supersedeTerminal(terminal)) return false;
        self.page.branch_status_load.markFailure(self.page.branch_status.repo_root != null);
        self.failActiveMember(.branch);
        return true;
    }

    pub fn rejectSourceSpawn(self: Controller, allocator: std.mem.Allocator, generation: u64) bool {
        if (self.page.canonical_publication) |gate| {
            if (gate.source_generation == generation) {
                self.abortCanonicalPublication(allocator);
                if (!self.page.load.hasPending() and self.page.load.state == .loading) {
                    self.page.load.state = .idle;
                }
                return true;
            }
        }
        _ = self.page.load.clearPendingIfCurrent(.{ .diff_load = generation });
        self.clearPendingReloadIfGeneration(allocator, generation);
        if (!self.page.load.hasPending() and self.page.load.state == .loading) {
            self.page.load.state = .idle;
        }
        self.failActiveMember(.source);
        return false;
    }

    fn canonicalSourceChanges(self: Controller, gate: anytype) bool {
        const deferred = self.page.deferred_source_apply orelse return false;
        if (deferred.mode != .canonical_publication or
            deferred.finished.generation != gate.source_generation) return false;
        return switch (deferred.finished.result) {
            .unchanged => false,
            .empty => true,
            .loaded => |bundle| if (gate.kind == .watch)
                if (self.navigation.view().activeLoadedDiffConst()) |loaded|
                    !std.mem.eql(u8, loaded.text, bundle.loaded.text)
                else
                    true
            else
                true,
            .failed, .failed_static => false,
        };
    }

    fn canonicalStatusRevision(self: Controller, gate: anytype) u64 {
        return self.page.status_snapshot_revision + @intFromBool(gate.status.changesSnapshot());
    }

    fn canonicalCandidateSourceFile(
        self: Controller,
        gate: anytype,
    ) ?diff_parser.FileDiff {
        const deferred = self.page.deferred_source_apply orelse return null;
        if (deferred.mode != .canonical_publication or
            deferred.finished.generation != gate.source_generation) return null;
        const document = switch (deferred.finished.result) {
            .loaded => |bundle| bundle.loaded.document,
            .unchanged => if (self.navigation.view().activeLoadedDiffConst()) |loaded|
                loaded.document
            else
                return null,
            .empty, .failed, .failed_static => return null,
        };
        for (document.files) |file| {
            const path_key = diff_file.canonicalPathKey(file) orelse continue;
            if (std.mem.eql(u8, path_key, gate.path_key)) return file;
        }
        return null;
    }

    fn canonicalExpectedPresentation(
        self: Controller,
        gate: anytype,
        target: ProjectionTarget,
    ) ?review_projection.ExpectedPresentation {
        const expected = self.expectedPresentationForTarget(target) orelse return null;
        if (expected.owner != .primary_loaded or !self.canonicalSourceChanges(gate)) {
            return expected;
        }
        const primary = switch (self.navigation.view().displayedReviewBody()) {
            .primary => |value| value,
            else => return null,
        };
        const candidate = self.canonicalCandidateSourceFile(gate) orelse return null;
        return if (diff_presentation_identity.exactEqual(
            primary.loaded.document.files[primary.file_index],
            candidate,
        ))
            expected
        else
            null;
    }

    fn canonicalProjectionKind(
        self: Controller,
        gate: anytype,
    ) ?review_projection.Kind {
        const status_document = self.canonicalStatusDocument(gate);
        for (status_document.entries) |entry| {
            const path_key = entry.canonicalPathKey() orelse continue;
            if (!std.mem.eql(u8, path_key, gate.path_key)) continue;
            return switch (file_tree.stagePresenceFromEntry(entry)) {
                .mixed => if (self.canonicalCandidateSourceFile(gate) != null)
                    .combined_hunks
                else
                    .cached_diff,
                .staged_only => .cached_diff,
                .untracked => .generated_added_file,
                .unstaged_only, .conflict, .clean_or_unknown => null,
            };
        }
        return null;
    }

    fn commitCanonicalNoop(
        self: Controller,
        allocator: std.mem.Allocator,
    ) void {
        const gate = if (self.page.canonical_publication) |*value| value else return;
        var deferred = self.page.deferred_source_apply orelse return;
        std.debug.assert(deferred.mode == .canonical_publication);
        std.debug.assert(deferred.finished.generation == gate.source_generation);
        if (!self.sourceTerminalOwnsPending(&deferred.finished)) {
            self.abortCanonicalPublication(allocator);
            return;
        }
        const fingerprint = canonicalSourceFingerprint(&deferred);
        const source_completion = self.page.action_cursor.captureCompletion(
            deferred.finished.identity.repo_epoch,
            .source,
            deferred.finished.generation,
        );
        var pending_reload = self.takeOwnedSourceTerminal(&deferred.finished) orelse unreachable;
        defer pending_reload.deinit(allocator);
        self.page.deferred_source_apply = null;
        self.page.status_load.markSuccess();
        if (self.acceptSourceFingerprint(fingerprint)) |failure| {
            _ = self.page.status.clearSourceReloadFailure(failure.digest);
        }
        _ = self.page.activation.finishMember(
            deferred.finished.identity,
            .source,
            self.acceptedSourceMember(),
        );
        if (source_completion) |completion| {
            _ = self.page.action_cursor.finishCompletion(completion, true);
        }
        _ = self.navigation.finalizeActionCursor(allocator);
        if (deferred.cycle_id != 0) {
            self.page.auto_reload.finishMember(
                deferred.cycle_id,
                .deferred_source_apply,
            );
        }
        deferred.deinit(allocator);
        var finished_gate = self.page.canonical_publication.?;
        self.page.canonical_publication = null;
        finished_gate.deinit(allocator);
    }

    fn commitCanonicalPrimary(
        self: Controller,
        allocator: std.mem.Allocator,
    ) !void {
        const gate = if (self.page.canonical_publication) |*value| value else return;
        var deferred = self.page.deferred_source_apply orelse return;
        if (deferred.mode != .canonical_publication or
            deferred.finished.generation != gate.source_generation or
            !self.sourceTerminalOwnsPending(&deferred.finished))
        {
            self.abortCanonicalPublication(allocator);
            return;
        }
        const source_changes = self.canonicalSourceChanges(gate);
        const status_changes = gate.status.changesSnapshot();
        const expected_source_revision = self.page.source_session_revision +
            @intFromBool(source_changes);
        const expected_status_revision = self.canonicalStatusRevision(gate);
        const fingerprint = canonicalSourceFingerprint(&deferred);
        var final_anchor = try self.view().captureAnchor(allocator);
        defer if (final_anchor) |*anchor| anchor.deinit(allocator);
        var prepared_source = self.prepareCanonicalSource(
            allocator,
            gate,
            &deferred,
        ) catch |err| {
            self.abortCanonicalPublication(allocator);
            return err;
        };
        defer prepared_source.deinit(allocator);
        var prepared_tree = if (!source_changes and status_changes)
            self.prepareCanonicalCurrentTree(
                allocator,
                self.canonicalStatusDocument(gate),
            ) catch |err| {
                self.abortCanonicalPublication(allocator);
                return err;
            }
        else
            null;

        gate.phase = .committing;
        const source_completion = self.page.action_cursor.captureCompletion(
            deferred.finished.identity.repo_epoch,
            .source,
            deferred.finished.generation,
        );
        var pending_reload = self.takeOwnedSourceTerminal(&deferred.finished) orelse unreachable;
        defer pending_reload.deinit(allocator);
        self.page.deferred_source_apply = null;

        if (source_changes or status_changes) {
            self.page.file_search.markProjectionUnavailable(allocator);
            self.page.accepted_sidebar_revision = file_search.nextAcceptedSidebarRevision(
                self.page.accepted_sidebar_revision,
            );
        }
        self.page.review_projection.clearPending(allocator);
        self.page.review_projection.clearSyntaxPending(allocator);
        self.page.review_projection.clearDisplayed(allocator);
        self.page.review_projection.clearCache(allocator);
        self.clearCompletedSelection(allocator);
        self.page.staged_hunks.clear(allocator);

        var retiring_status: ?git_status.GitStatusState = null;
        if (gate.status.takeReplacement()) |replacement| {
            retiring_status = self.page.git_status;
            self.page.git_status = replacement;
        }
        self.page.status_snapshot_revision = expected_status_revision;

        var retiring_load: ?load_state.LoadState = null;
        if (source_changes) {
            retiring_load = self.page.load.state;
            switch (prepared_source) {
                .loaded => |session| {
                    self.page.load.state = .{ .loaded = session };
                    prepared_source = .unchanged;
                },
                .empty => self.page.load.state = .{ .empty = .no_changes },
                .unchanged => unreachable,
            }
            self.page.source_session_revision = expected_source_revision;
        }
        if (prepared_tree) |*tree| self.installCanonicalCurrentTree(tree);

        if (final_anchor) |*anchor| {
            if (self.navigation.activeLoadedDiff()) |loaded| {
                _ = self.navigation.restoreReloadAnchor(loaded, anchor);
            }
            self.restoreDisplayedNavigation(anchor);
        } else {
            self.navigation.refreshSearchForSelectedFile();
        }
        self.page.status_load.markSuccess();
        self.page.pending_initial_first_visible_selection = false;
        if (self.acceptSourceFingerprint(fingerprint)) |failure| {
            _ = self.page.status.clearSourceReloadFailure(failure.digest);
        }
        _ = self.page.activation.finishMember(
            deferred.finished.identity,
            .source,
            self.acceptedSourceMember(),
        );
        if (source_completion) |completion| {
            _ = self.page.action_cursor.finishCompletion(completion, true);
        }
        _ = self.navigation.finalizeActionCursor(allocator);
        self.navigation.rebuildFileSearchProjection(allocator);

        if (retiring_load) |*state| deinitRetiringLoadState(state, allocator);
        if (retiring_status) |*status| status.deinit();
        if (deferred.cycle_id != 0) {
            self.page.auto_reload.finishMember(
                deferred.cycle_id,
                .deferred_source_apply,
            );
        }
        deferred.deinit(allocator);
        var finished_gate = self.page.canonical_publication.?;
        self.page.canonical_publication = null;
        finished_gate.deinit(allocator);
    }

    fn prepareCanonicalProjection(
        self: Controller,
        allocator_opt: ?std.mem.Allocator,
    ) !ReviewUpdate {
        const gate = if (self.page.canonical_publication) |*value| value else return .{};
        if (gate.phase == .waiting_projection) return .{};
        if (gate.phase != .waiting_members or !gate.status.ready()) return .{};
        const deferred = self.page.deferred_source_apply orelse return .{};
        if (deferred.mode != .canonical_publication or
            deferred.finished.generation != gate.source_generation) return .{};

        const allocator = allocator_opt orelse return error.MissingAllocator;
        errdefer self.abortCanonicalPublication(allocator);
        _ = try self.refreshCanonicalPath(allocator, gate);
        const source_changes = self.canonicalSourceChanges(gate);
        const status_changes = gate.status.changesSnapshot();
        const projection_kind = self.canonicalProjectionKind(gate) orelse {
            if (!source_changes and !status_changes) {
                self.commitCanonicalNoop(allocator);
            } else {
                try self.commitCanonicalPrimary(allocator);
            }
            return .{};
        };
        const target: ProjectionTarget = .{
            .repo_root = gate.repo_root,
            .path_key = gate.path_key,
            .kind = projection_kind,
            .source_kind = sourceKind(self.source),
        };
        if (!source_changes and !status_changes) {
            const displayed = self.page.review_projection.displayed.request();
            if (displayed != null and displayed.?.matchesBorrowed(
                gate.read_epoch,
                target.repo_root,
                target.path_key,
                target.kind,
                target.source_kind,
                self.page.source_session_revision,
                self.page.status_snapshot_revision,
            )) {
                self.commitCanonicalNoop(allocator);
                return .{};
            }
        }
        const expected_presentation = self.canonicalExpectedPresentation(gate, target);
        const source_revision = self.page.source_session_revision +
            @intFromBool(source_changes);
        const status_revision = self.canonicalStatusRevision(gate);

        self.page.review_projection_next_id +%= 1;
        if (self.page.review_projection_next_id == 0) self.page.review_projection_next_id = 1;
        const request_id = self.page.review_projection_next_id;
        var state_request = try review_projection.cloneRequestWithOptions(
            allocator,
            gate.identity,
            request_id,
            gate.repo_root,
            gate.path_key,
            target.kind,
            target.source_kind,
            source_revision,
            status_revision,
            .{
                .read_epoch = gate.read_epoch,
                .root_identity = self.root_identity,
                .expected_presentation = expected_presentation,
            },
        );
        errdefer state_request.deinit(allocator);
        var task_request = try review_projection.cloneRequestWithOptions(
            allocator,
            gate.identity,
            request_id,
            gate.repo_root,
            gate.path_key,
            target.kind,
            target.source_kind,
            source_revision,
            status_revision,
            .{
                .read_epoch = gate.read_epoch,
                .root_identity = self.root_identity,
                .expected_presentation = expected_presentation,
            },
        );
        errdefer task_request.deinit(allocator);

        self.page.review_projection.clearPending(allocator);
        self.page.review_projection.pending = state_request;
        state_request = undefined;
        gate.phase = .waiting_projection;
        gate.projection_request_id = request_id;
        return .{ .command = .{ .review_projection = task_request } };
    }

    /// Reconciles projection identity and, only when a read is required,
    /// transfers one owned task request to the shell. The pending page identity
    /// is a distinct clone so task and page never share allocator ownership.
    pub fn prepareProjection(self: Controller, allocator_opt: ?std.mem.Allocator) !ReviewUpdate {
        // A closed mutation phase retains the old displayed/cache owners as
        // inert visual state. Do not reconcile, promote a cache hit, clear a
        // no-target display, or prepare a current-epoch request until the exact
        // action terminal reopens repository-read authority.
        if (!self.page.repository_read_authority.mayStartRepositoryRead()) return .{};

        // Projection reconciliation can move or free the currently displayed
        // owner. A live drag borrows that owner, so even cache promotion and
        // no-target cleanup wait until release/cancel has ended the borrow.
        if (self.displayMutationBlockedByDrag()) return .{};
        if (self.page.canonical_publication != null) {
            return self.prepareCanonicalProjection(allocator_opt);
        }
        const read_epoch = self.page.repository_read_authority.epoch;

        const target = self.view().projectionTarget() orelse {
            _ = self.page.review_projection.shouldForceEagerRetry(null);
            if (self.view().canRetainDisplayedProjection()) return .{};
            if (self.page.pending_display_navigation_restore != null and !self.page.status_load.isFresh()) return .{};
            const allocator = allocator_opt orelse {
                if (!self.page.review_projection.hasPending() and
                    !self.page.review_projection.hasDisplayed() and
                    self.page.review_projection.cacheLen() == 0 and
                    self.page.pending_display_navigation_restore == null) return .{};
                return error.MissingAllocator;
            };
            const outgoing_lineage = self.currentOwnedProjectionLineage();
            self.page.review_projection.clearPending(allocator);
            if (self.combinedToOrdinaryBoundary()) |boundary| {
                // A self-owned combined body is always unfolded, while the
                // underlying primary may retain folds from before projection
                // activation. Capture semantic/offset fallback before owner
                // teardown and restore it against the primary rendered model.
                // Primary-backed authority already displays that exact model
                // and therefore needs no cross-model anchor allocation.
                var local_navigation = if (boundary.owner == .self_owned and
                    self.page.pending_display_navigation_restore == null)
                    try self.view().captureAnchor(allocator)
                else
                    null;
                defer if (local_navigation) |*anchor| anchor.deinit(allocator);

                const has_navigation_authority = boundary.owner == .primary_backed or
                    self.page.pending_display_navigation_restore != null or
                    local_navigation != null;
                if (has_navigation_authority) {
                    self.applyPresentationLineageTransfer(allocator, boundary.transfer);
                    self.page.review_projection.finishCombinedToOrdinaryPrimary(allocator);
                    switch (boundary.owner) {
                        .self_owned => self.reconcileInstalledProjectionNavigation(
                            allocator,
                            if (local_navigation) |*anchor| anchor else null,
                        ),
                        .primary_backed => self.reconcileRetainedPresentationNavigation(allocator),
                    }
                    return .{};
                }
            }
            if (outgoing_lineage) |lineage| self.clearPresentationLineage(allocator, lineage);
            self.reconcileCompletedSelectionForNoProjectionTarget(allocator);
            if (self.page.pending_display_navigation_restore != null) self.clearDisplayRestore(allocator);
            if (self.repo_root) |repo_root| {
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
                    read_epoch,
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
            read_epoch,
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
            read_epoch,
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
                read_epoch,
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
                const outgoing_lineage = self.currentPresentationLineageForPath(
                    target.repo_root,
                    target.path_key,
                );
                if (self.retainCombinedPresentationTokenIfExact(
                    target.repo_root,
                    target.path_key,
                    &hit.value,
                )) |transfer| {
                    self.applyPresentationLineageTransfer(allocator, transfer);
                } else if (outgoing_lineage) |lineage| {
                    self.clearPresentationLineage(allocator, lineage);
                }
                self.reconcileCompletedSelectionForReady(allocator, .{
                    .repo_root = target.repo_root,
                    .path_key = target.path_key,
                }, &hit.value);
                self.page.review_projection.clearPending(allocator);
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
                    read_epoch,
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
            read_epoch,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) return .{};

        self.page.review_projection.clearPending(allocator);
        const live_expected_presentation = self.expectedPresentationForTarget(target);
        const primary_reuse_candidate = if (live_expected_presentation) |expected|
            expected.owner == .primary_loaded
        else
            false;
        const selection_scope: ProjectionSelectionScope = .{
            .repo_root = target.repo_root,
            .path_key = target.path_key,
        };
        if (!self.view().displayedMatchesStableIdentity(target)) {
            if (!primary_reuse_candidate) self.clearCompletedSelectionForProjection(allocator, selection_scope);
            // The first all-unstaged -> combined request has no projection
            // owner to cache or clear. Avoid consuming its eager-retry marker
            // and keep the owned primary selection until exact acceptance or
            // the terminal eager replacement decides its content basis.
            if (!primary_reuse_candidate or self.page.review_projection.hasDisplayed()) {
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
                    read_epoch,
                    target.repo_root,
                    target.source_kind,
                    self.page.source_session_revision,
                    self.page.status_snapshot_revision,
                );
            }
        }
        self.page.review_projection_next_id +%= 1;
        const request_id = self.page.review_projection_next_id;
        const identity = self.page.activation.currentIdentity() orelse {
            self.clearCompletedSelectionForProjection(allocator, selection_scope);
            return .{};
        };

        // From this point a fresh replacement request is the only terminal
        // which can validate a combined candidate retained across status
        // acceptance. If either owned request clone cannot be constructed,
        // no completion will arrive to reconcile that candidate.
        errdefer self.clearCompletedSelectionForProjection(allocator, selection_scope);

        const request_root_identity = if (target.kind == .generated_added_file) self.root_identity else null;
        const force_eager_retry = self.page.review_projection.shouldForceEagerRetry(live_expected_presentation);
        const expected_presentation = if (force_eager_retry) null else live_expected_presentation;
        var state_request = try review_projection.cloneRequestWithOptions(
            allocator,
            identity,
            request_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
            .{
                .read_epoch = read_epoch,
                .root_identity = request_root_identity,
                .expected_presentation = expected_presentation,
            },
        );
        errdefer state_request.deinit(allocator);

        var task_request = try review_projection.cloneRequestWithOptions(
            allocator,
            identity,
            request_id,
            target.repo_root,
            target.path_key,
            target.kind,
            target.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
            .{
                .read_epoch = read_epoch,
                .root_identity = request_root_identity,
                .expected_presentation = expected_presentation,
            },
        );
        errdefer task_request.deinit(allocator);

        self.page.review_projection.pending = state_request;
        state_request = undefined;
        return .{ .command = .{ .review_projection = task_request } };
    }

    /// Shell validation/allocation/spawn failure terminal for a prepared read.
    /// It clears only the matching page clone and the candidate which was
    /// awaiting that replacement. The command/task owner frees its own request
    /// independently; a stale rejection cannot disturb a newer request.
    pub fn rejectProjectionSpawn(self: Controller, allocator: std.mem.Allocator, request_id: u64) void {
        const pending = if (self.page.review_projection.pending) |*request| request else return;
        if (pending.id != request_id) return;
        if (self.page.canonical_publication) |gate| {
            if (gate.projection_request_id == request_id) {
                self.abortCanonicalPublication(allocator);
                return;
            }
        }
        self.clearCompletedSelectionForProjection(allocator, .{
            .repo_root = pending.repo_root,
            .path_key = pending.path_key,
        });
        self.page.review_projection.clearPending(allocator);
    }

    /// Retire an already-proved exact async terminal without publishing it.
    /// Selection, hunk marks, displayed/cache owners, navigation restore, and
    /// eager-retry state belong to the retained presentation or a successor
    /// request; an old completion has authority over none of them.
    fn retireProjectionTerminalWithoutPublication(
        self: Controller,
        allocator: std.mem.Allocator,
    ) ProjectionApply {
        self.page.review_projection.clearPending(allocator);
        return .{ .skip_redraw = true };
    }

    /// Prepares optional syntax only for the current plain generated preview.
    /// The bundle remains `eligible` while the page-owned pending request is
    /// in flight, so immutable cache admission never needs to mutate an entry.
    pub fn prepareGeneratedSyntax(self: Controller, allocator: std.mem.Allocator) !?review_projection.GeneratedSyntaxRequest {
        if (!self.page.repository_read_authority.mayStartRepositoryRead()) return null;
        if (!source_syntax_runtime.enabled) return null;
        const target = self.view().projectionTarget() orelse return null;
        if (target.kind != .generated_added_file) return null;

        const ready = switch (self.page.review_projection.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => return null,
        };
        if (!ready.request.matchesBorrowed(
            self.page.repository_read_authority.epoch,
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
                pending.read_epoch.eql(ready.request.read_epoch) and
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
    ) GeneratedSyntaxApply {
        // Pending equality proves cleanup ownership independently of current
        // publication authority. Drain the exact page clone first; every
        // rejection below leaves the retained generated body unchanged.
        const pending = self.page.review_projection.syntax_pending orelse return .{ .skip_redraw = true };
        if (!pending.matches(finished.request)) return .{ .skip_redraw = true };
        self.page.review_projection.clearSyntaxPending(allocator);

        const current_identity = self.page.activation.currentIdentity() orelse return .{ .skip_redraw = true };
        if (current_identity.origin != finished.request.identity.origin or
            current_identity.repo_epoch != finished.request.identity.repo_epoch or
            current_identity.activation_id != finished.request.identity.activation_id)
        {
            return .{ .skip_redraw = true };
        }
        if (!self.page.repository_read_authority.acceptsRead(finished.request.read_epoch)) {
            return .{ .skip_redraw = true };
        }
        const active_root = self.root_identity orelse return .{ .skip_redraw = true };
        if (!active_root.eql(finished.request.root_identity)) return .{ .skip_redraw = true };

        const target = self.view().projectionTarget() orelse return .{ .skip_redraw = true };
        if (target.kind != .generated_added_file) return .{ .skip_redraw = true };
        const ready = switch (self.page.review_projection.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => return .{ .skip_redraw = true },
        };
        if (ready.request.id != finished.request.projection_id or
            !ready.request.read_epoch.eql(finished.request.read_epoch) or
            !ready.request.matchesRootIdentity(active_root) or
            !ready.request.matchesBorrowed(
                self.page.repository_read_authority.epoch,
                target.repo_root,
                target.path_key,
                target.kind,
                target.source_kind,
                self.page.source_session_revision,
                self.page.status_snapshot_revision,
            )) return .{ .skip_redraw = true };
        const bundle = switch (ready.value) {
            .generated_added_file => |*bundle| bundle,
            else => return .{ .skip_redraw = true },
        };
        if (!bundle.fingerprint().eql(finished.request.expected_fingerprint)) {
            return .{ .skip_redraw = true };
        }

        switch (finished.result) {
            .loaded => |spans| {
                const snapshot = finished.snapshot_fingerprint orelse {
                    bundle.decoration = .{ .terminal_plain = .snapshot_changed };
                    return .{};
                };
                if (!snapshot.eql(finished.request.expected_fingerprint) or
                    !snapshot.eql(bundle.fingerprint()))
                {
                    bundle.decoration = .{ .terminal_plain = .snapshot_changed };
                    return .{};
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
        return .{};
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

    /// Exact reuse leaves the rendered coordinate system unchanged. Preserve
    /// the current search match, cursor, and scroll rather than treating the
    /// accepted authority as a file replacement and jumping to the first
    /// match. A pending cross-load restore still has higher authority; without
    /// one, only the derived rendered offset needs revalidation.
    fn reconcileRetainedPresentationNavigation(
        self: Controller,
        allocator: std.mem.Allocator,
    ) void {
        if (self.page.pending_display_navigation_restore) |*restore| {
            self.restoreDisplayedNavigation(restore.authoritative());
            self.clearDisplayRestore(allocator);
        } else {
            self.navigation.updateSearchMatchOffset();
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
            .failed => |message| try self.replaceSourceFailure(allocator, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| try self.replaceSourceFailure(allocator, message),
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
        const terminal: auto_reload.AuxiliaryTerminal = .{
            .generation = result.generation,
            .read_epoch = result.read_epoch,
            .background_cycle_id = result.background_cycle_id,
        };
        const drain_terminal = if (self.page.canonical_status_drain) |drain|
            drain.generation == terminal.generation and
                drain.read_epoch.eql(terminal.read_epoch) and
                drain.background_cycle_id == terminal.background_cycle_id
        else
            false;
        const drain_only_terminal = if (self.page.status_load.pending) |pending|
            pending.matchesTerminal(terminal) and !pending.publication_allowed
        else
            false;
        const drain_action_member = drain_only_terminal and
            self.page.action_cursor.captureCompletion(
                result.identity.repo_epoch,
                .status,
                result.generation,
            ) != null;
        const canonical_terminal = self.canonicalGateMatchesStatus(result);
        const publication_admitted = !background_blocked and
            self.acceptsIdentity(result.identity) and
            self.acceptsRepositoryReadCompletion(result.read_epoch, result.background_cycle_id) and
            self.page.status_load.acceptsPublication(terminal);
        self.page.auto_reload.finishMember(result.background_cycle_id, .status);
        const owns_terminal = self.page.status_load.finishTerminal(terminal);
        if (drain_terminal) {
            self.page.canonical_status_drain = null;
            if (owns_terminal) {
                self.page.status_load.markFailure(self.page.git_status.repo_root != null);
                _ = self.page.activation.finishMember(result.identity, .status, .failed);
            }
            return .{
                .skip_redraw = true,
                .terminal_admitted = owns_terminal and drain_action_member,
            };
        }
        if (!owns_terminal) return .{ .skip_redraw = true };
        if (!publication_admitted) {
            if (canonical_terminal) self.abortCanonicalPublication(allocator);
            return .{
                .skip_redraw = true,
                .terminal_admitted = drain_action_member,
            };
        }

        if (canonical_terminal) {
            switch (result.result) {
                .empty => {
                    const same_root = if (self.page.git_status.repo_root) |root|
                        std.mem.eql(u8, root, result.repo_root)
                    else
                        false;
                    if (same_root and self.page.git_status.document.entries.len == 0) {
                        self.page.canonical_publication.?.status = .identical;
                    } else {
                        self.page.canonical_publication.?.status = .{ .replacement = .{} };
                    }
                    _ = self.page.activation.finishMember(result.identity, .status, .fresh);
                    self.page.pending_initial_first_visible_selection = false;
                    return .{ .skip_redraw = true, .terminal_admitted = true };
                },
                .loaded => |*bundle| {
                    const identical = if (self.page.git_status.repo_root) |root|
                        std.mem.eql(u8, root, result.repo_root) and
                            self.page.git_status.document.eql(bundle.document)
                    else
                        false;
                    if (identical) {
                        self.page.canonical_publication.?.status = .identical;
                    } else {
                        var candidate: git_status.GitStatusState = .{};
                        candidate.replace(result.repo_root, bundle) catch |err| {
                            self.abortCanonicalPublication(allocator);
                            return err;
                        };
                        self.page.canonical_publication.?.status = .{ .replacement = candidate };
                        result.result = .empty;
                    }
                    _ = self.page.activation.finishMember(result.identity, .status, .fresh);
                    self.page.pending_initial_first_visible_selection = false;
                    return .{ .skip_redraw = true, .terminal_admitted = true };
                },
                .failed => |message| return self.applyCanonicalStatusFailure(
                    allocator,
                    result.identity,
                    std.mem.trim(u8, message, " \t\r\n"),
                ),
                .failed_static => |message| return self.applyCanonicalStatusFailure(
                    allocator,
                    result.identity,
                    message,
                ),
            }
        }

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
                return .{ .project_status = prefer_first, .terminal_admitted = true };
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
                        return .{ .skip_redraw = true, .terminal_admitted = true };
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
                return .{ .project_status = prefer_first, .terminal_admitted = true };
            },
            .failed => |message| return self.applyStatusFailure(allocator, result.identity, result.background_cycle_id, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| return self.applyStatusFailure(allocator, result.identity, result.background_cycle_id, message),
        }
    }

    fn applyCanonicalStatusFailure(
        self: Controller,
        allocator: std.mem.Allocator,
        identity: app_page.RequestIdentity,
        message: []const u8,
    ) CompletionApply {
        self.page.status_load.markFailure(self.page.git_status.repo_root != null);
        _ = self.page.activation.finishMember(identity, .status, .failed);
        self.page.pending_initial_first_visible_selection = false;
        self.abortCanonicalPublication(allocator);
        return .{
            .diagnostic = .{ .status_load_failed = message },
            .terminal_admitted = true,
        };
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
        return .{ .diagnostic = .{ .status_load_failed = message }, .terminal_admitted = true };
    }

    pub fn applyBranchStatusFinished(
        self: Controller,
        result: *app_load.BranchStatusLoadFinished,
        background_blocked: bool,
    ) CompletionApply {
        const terminal: auto_reload.AuxiliaryTerminal = .{
            .generation = result.generation,
            .read_epoch = result.read_epoch,
            .background_cycle_id = result.background_cycle_id,
        };
        const publication_admitted = !background_blocked and
            self.acceptsIdentity(result.identity) and
            self.acceptsRepositoryReadCompletion(result.read_epoch, result.background_cycle_id) and
            self.page.branch_status_load.acceptsPublication(terminal);
        self.page.auto_reload.finishMember(result.background_cycle_id, .branch);
        const owns_terminal = self.page.branch_status_load.finishTerminal(terminal);
        if (!owns_terminal or !publication_admitted) return .{ .skip_redraw = true };

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
                    return .{ .skip_redraw = true, .terminal_admitted = true };
                }
                self.page.branch_status.replace(result.repo_root, bundle) catch {
                    self.page.branch_status.clear();
                    self.page.branch_status_load.markFailure(false);
                    _ = self.page.activation.finishMember(result.identity, .branch, .failed);
                    return .{ .diagnostic = .branch_status_parse_failed, .terminal_admitted = true };
                };
                self.page.branch_status_load.markSuccess();
                _ = self.page.activation.finishMember(result.identity, .branch, .fresh);
                result.result = .empty;
            },
            .failed => |message| return self.applyBranchFailure(result.identity, result.background_cycle_id, std.mem.trim(u8, message, " \t\r\n")),
            .failed_static => |message| return self.applyBranchFailure(result.identity, result.background_cycle_id, message),
        }
        return .{ .terminal_admitted = true };
    }

    fn applyBranchFailure(self: Controller, identity: app_page.RequestIdentity, background_cycle_id: ?u64, message: []const u8) CompletionApply {
        const retain = background_cycle_id != null and self.page.branch_status.repo_root != null;
        self.page.branch_status_load.markFailure(retain);
        _ = self.page.activation.finishMember(identity, .branch, .failed);
        if (!retain) self.page.branch_status.clear();
        return .{ .diagnostic = .{ .branch_status_load_failed = message }, .terminal_admitted = true };
    }

    fn canonicalStatusDocument(
        self: Controller,
        gate: anytype,
    ) git_status.StatusDocument {
        return switch (gate.status) {
            .pending => unreachable,
            .identical => self.page.git_status.document,
            .replacement => |status| status.document,
        };
    }

    fn prepareCanonicalLoadedSource(
        self: Controller,
        allocator: std.mem.Allocator,
        bundle: *app_load.LoadedDiffBundle,
        status_document: git_status.StatusDocument,
    ) !PreparedCanonicalSource {
        var arena = bundle.takeArena();
        errdefer arena.deinit();
        var loaded = bundle.loaded;
        try self.navigation.materializeReviewedFiles(allocator, &loaded);
        errdefer allocator.free(loaded.reviewed_files);
        try self.navigation.ensureTreeOrderScope(allocator);
        loaded.tree = try file_tree.buildWithOptions(
            arena.allocator(),
            loaded.document,
            status_document,
            .{
                .root = self.navigation.view().fileTreeRootOptions(),
                .stable_order = self.navigation.stableOrderOptions(allocator),
            },
        );
        try loaded.rebuildVisibleNodes(
            arena.allocator(),
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        return .{ .loaded = .{
            .arena = arena,
            .loaded = loaded,
            .reviewed_files_owned = true,
        } };
    }

    fn prepareCanonicalStatusOnlySource(
        self: Controller,
        allocator: std.mem.Allocator,
        status_document: git_status.StatusDocument,
    ) !PreparedCanonicalSource {
        if (status_document.entries.len == 0) return .empty;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const document = diff_parser.DiffDocument{ .files = &.{} };
        try self.navigation.ensureTreeOrderScope(allocator);
        var loaded: loaded_diff.LoadedDiff = .{
            .text = "",
            .document = document,
            .file_text_eligibility = &.{},
            .tree = try file_tree.buildWithOptions(
                arena_allocator,
                document,
                status_document,
                .{
                    .root = self.navigation.view().fileTreeRootOptions(),
                    .stable_order = self.navigation.stableOrderOptions(allocator),
                },
            ),
            .rendered_line_cache = try diff_view_model.RenderedLineCache.build(
                arena_allocator,
                document,
            ),
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
        return .{ .loaded = .{
            .arena = arena,
            .loaded = loaded,
            .reviewed_files_owned = false,
        } };
    }

    fn prepareCanonicalSource(
        self: Controller,
        allocator: std.mem.Allocator,
        gate: anytype,
        deferred: *review_page.DeferredSourceApply,
    ) !PreparedCanonicalSource {
        if (!self.canonicalSourceChanges(gate)) return .unchanged;
        const status_document = self.canonicalStatusDocument(gate);
        return switch (deferred.finished.result) {
            .empty => self.prepareCanonicalStatusOnlySource(allocator, status_document),
            .loaded => |*bundle| self.prepareCanonicalLoadedSource(
                allocator,
                bundle,
                status_document,
            ),
            .unchanged => .unchanged,
            .failed, .failed_static => unreachable,
        };
    }

    fn prepareCanonicalCurrentTree(
        self: Controller,
        app_allocator: std.mem.Allocator,
        status_document: git_status.StatusDocument,
    ) !?PreparedCanonicalCurrentTree {
        const loaded = self.navigation.activeLoadedDiff() orelse return null;
        const allocator = self.navigation.loadArenaAllocator() orelse return null;
        const previous_path_key = self.navigation.view().selectedStagePathKey();
        const previous_sidebar_identity = self.navigation.view().selectedSidebarIdentity();
        try self.navigation.ensureTreeOrderScope(app_allocator);
        const tree = try file_tree.buildWithOptions(
            allocator,
            loaded.document,
            status_document,
            .{
                .root = self.navigation.view().fileTreeRootOptions(),
                .stable_order = self.navigation.stableOrderOptions(app_allocator),
            },
        );
        var shadow = loaded.*;
        shadow.tree = tree;
        shadow.visible_nodes = &.{};
        shadow.visible_node_count = 0;
        try shadow.rebuildVisibleNodes(
            allocator,
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        return .{
            .tree = tree,
            .visible_nodes = shadow.visible_nodes,
            .visible_node_count = shadow.visible_node_count,
            .root_disclosure = shadow.root_disclosure,
            .previous_path_key = previous_path_key,
            .previous_sidebar_identity = previous_sidebar_identity,
        };
    }

    fn installCanonicalCurrentTree(
        self: Controller,
        prepared: *PreparedCanonicalCurrentTree,
    ) void {
        const loaded = self.navigation.activeLoadedDiff() orelse unreachable;
        loaded.tree = prepared.tree;
        loaded.visible_nodes = prepared.visible_nodes;
        loaded.visible_node_count = prepared.visible_node_count;
        loaded.root_disclosure = prepared.root_disclosure;
        if (prepared.previous_path_key) |path_key| {
            if (navigation.findFileNodeByPathKey(loaded, path_key)) |node_index| {
                self.navigation.selectSidebarNode(loaded, node_index);
            }
        }
        if (prepared.previous_sidebar_identity) |identity| {
            _ = self.navigation.restoreSidebarIdentity(loaded, identity);
        }
        self.navigation.reconcileSelectionAfterVisibleNodeChange(loaded);
        prepared.* = undefined;
    }

    fn canonicalSourceFingerprint(
        deferred: *const review_page.DeferredSourceApply,
    ) content_fingerprint.Fingerprint {
        return switch (deferred.finished.result) {
            .empty => content_fingerprint.Fingerprint.init(""),
            .unchanged => |fingerprint| fingerprint,
            .loaded => |bundle| bundle.fingerprint,
            .failed, .failed_static => unreachable,
        };
    }

    fn deinitRetiringLoadState(
        state: *load_state.LoadState,
        allocator: std.mem.Allocator,
    ) void {
        switch (state.*) {
            .loaded => |*session| session.deinit(allocator),
            .failed => |*failed| failed.deinit(),
            .idle, .loading, .empty => {},
        }
        state.* = .idle;
    }

    fn acceptsCanonicalCombinedReuseCandidate(
        self: Controller,
        request: review_projection.Request,
        candidate: *const review_projection.CombinedReuseCandidate,
    ) bool {
        const expected = request.expected_presentation orelse return false;
        if (!candidate.fingerprint.eql(expected.fingerprint)) return false;
        const fresh = if (candidate.fresh_authority) |*value| value else return false;
        if (fresh.status_snapshot_revision != request.status_snapshot_revision) return false;
        if (fresh.cached_component.document.files.len != 1) return false;
        const candidate_hunks = candidate.displayFile().hunks.len;
        if (fresh.projection.hunk_stage_states.len != candidate_hunks or
            fresh.projection.hunk_action_origins.len != candidate_hunks) return false;

        return switch (expected.owner) {
            .combined_projection => blk: {
                const live = self.ownedCombinedPresentation() orelse break :blk false;
                if (!live.presentation.content_token.eql(expected.content_token)) break :blk false;
                if (!live.presentation.fingerprint.eql(expected.fingerprint)) break :blk false;
                break :blk diff_presentation_identity.exactEqual(
                    live.display_file,
                    candidate.displayFile(),
                );
            },
            .primary_loaded => blk: {
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |value| value,
                    else => break :blk false,
                };
                const live_file = primary.loaded.document.files[primary.file_index];
                if (!diff_presentation_identity.fingerprint(live_file).eql(expected.fingerprint)) {
                    break :blk false;
                }
                const expected_token = diff_presentation_identity.ContentToken.init(
                    self.page.source_session_revision,
                );
                if (!expected_token.eql(expected.content_token)) break :blk false;
                break :blk diff_presentation_identity.exactEqual(
                    live_file,
                    candidate.displayFile(),
                );
            },
        };
    }

    fn installCanonicalCombinedReuse(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) ?PresentationLineage {
        const candidate = &result.result.reuse_candidate;
        std.debug.assert(self.acceptsCanonicalCombinedReuseCandidate(
            result.request,
            candidate,
        ));
        const outgoing_lineage = self.currentPresentationLineageForPath(
            result.request.repo_root,
            result.request.path_key,
        );
        const expected_owner = result.request.expected_presentation.?.owner;
        self.page.review_projection.finishEagerRetry();
        self.page.review_projection.clearPending(allocator);
        const request = result.request;
        result.request = undefined;
        switch (expected_owner) {
            .combined_projection => self.page.review_projection.installCombinedReuse(
                allocator,
                request,
                candidate,
            ),
            .primary_loaded => self.page.review_projection.installPrimaryCombinedReuse(
                allocator,
                request,
                candidate,
            ),
        }
        candidate.deinit();
        result.result = undefined;
        self.reconcileRetainedPresentationNavigation(allocator);
        return outgoing_lineage;
    }

    fn acceptsCanonicalStagedOnlyReuseCandidate(
        self: Controller,
        request: review_projection.Request,
        candidate: *const review_projection.StagedOnlyReuseCandidate,
    ) bool {
        if (request.kind != .cached_diff) return false;
        const expected = request.expected_presentation orelse return false;
        if (!candidate.fingerprint.eql(expected.fingerprint)) return false;
        const fresh = if (candidate.fresh_authority) |*value| value else return false;
        if (fresh.status_snapshot_revision != request.status_snapshot_revision) return false;
        if (fresh.cached_component.document.files.len != 1) return false;
        const candidate_hunks = candidate.displayFile().hunks.len;
        if (fresh.projection.hunk_stage_states.len != candidate_hunks or
            fresh.projection.hunk_action_origins.len != candidate_hunks) return false;
        for (fresh.projection.hunk_stage_states, fresh.projection.hunk_action_origins, 0..) |state, origin, hunk_index| {
            if (state != .staged) return false;
            switch (origin) {
                .cached => |index| if (index != hunk_index) return false,
                .unstaged => return false,
            }
        }
        return switch (expected.owner) {
            .combined_projection => blk: {
                const live = self.navigation.view().activeCombinedProjection() orelse break :blk false;
                break :blk diff_presentation_identity.exactEqual(
                    live.displayFile(),
                    candidate.displayFile(),
                );
            },
            .primary_loaded => blk: {
                const primary = switch (self.navigation.view().displayedReviewBody()) {
                    .primary => |value| value,
                    else => break :blk false,
                };
                break :blk diff_presentation_identity.exactEqual(
                    primary.loaded.document.files[primary.file_index],
                    candidate.displayFile(),
                );
            },
        };
    }

    fn installCanonicalStagedOnlyReuse(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) ?PresentationLineage {
        const candidate = &result.result.staged_only_reuse_candidate;
        std.debug.assert(self.acceptsCanonicalStagedOnlyReuseCandidate(
            result.request,
            candidate,
        ));
        const outgoing_lineage = self.currentPresentationLineageForPath(
            result.request.repo_root,
            result.request.path_key,
        );
        const expected_owner = result.request.expected_presentation.?.owner;
        self.page.review_projection.finishEagerRetry();
        self.page.review_projection.clearPending(allocator);
        const request = result.request;
        result.request = undefined;
        switch (expected_owner) {
            .combined_projection => self.page.review_projection.installRetainedStagedOnlyReuse(
                allocator,
                request,
                candidate,
            ),
            .primary_loaded => self.page.review_projection.installPrimaryStagedOnlyReuse(
                allocator,
                request,
                candidate,
            ),
        }
        candidate.deinit();
        result.result = undefined;
        self.reconcileRetainedPresentationNavigation(allocator);
        return outgoing_lineage;
    }

    fn applyCanonicalProjectionFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) !ProjectionApply {
        const gate = if (self.page.canonical_publication) |*value| value else return .{ .skip_redraw = true };
        if (gate.phase != .waiting_projection or
            gate.projection_request_id != result.request.id) return .{ .skip_redraw = true };
        errdefer self.abortCanonicalPublication(allocator);
        if (try self.refreshCanonicalPath(allocator, gate)) {
            self.page.review_projection.clearPending(allocator);
            gate.phase = .waiting_members;
            gate.projection_request_id = null;
            return .{ .skip_redraw = true };
        }
        const source_changes = self.canonicalSourceChanges(gate);
        const expected_source_revision = self.page.source_session_revision +
            @intFromBool(source_changes);
        const expected_status_revision = self.canonicalStatusRevision(gate);
        const expected_kind = self.canonicalProjectionKind(gate) orelse {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        };
        if (!result.request.matchesBorrowed(
            gate.read_epoch,
            gate.repo_root,
            gate.path_key,
            expected_kind,
            sourceKind(self.source),
            expected_source_revision,
            expected_status_revision,
        ) or !result.request.matchesRootIdentity(self.root_identity)) {
            return .{ .skip_redraw = true };
        }
        if (!self.acceptsIdentity(result.request.identity) or
            !self.page.repository_read_authority.acceptsRead(result.request.read_epoch))
        {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        }

        if (self.displayMutationBlockedByDrag()) {
            if (self.page.deferred_projection_apply != null) return .{ .skip_redraw = true };
            self.page.deferred_projection_apply = .{ .finished = result.* };
            return .{ .result_transferred = true, .skip_redraw = true };
        }

        const combined_reuse = result.result == .reuse_candidate;
        const staged_only_reuse = result.result == .staged_only_reuse_candidate;
        const reused = combined_reuse or staged_only_reuse;
        if (combined_reuse and !self.acceptsCanonicalCombinedReuseCandidate(
            result.request,
            &result.result.reuse_candidate,
        )) {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        }
        if (staged_only_reuse and !self.acceptsCanonicalStagedOnlyReuseCandidate(
            result.request,
            &result.result.staged_only_reuse_candidate,
        )) {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        }
        var static_failure = switch (result.result) {
            .failed_static => |message| try review_projection.statusBodyAlloc(
                allocator,
                result.request.path_key,
                "{s}",
                .{message},
            ),
            else => null,
        };
        defer if (static_failure) |*body| body.deinit(allocator);

        var final_anchor = if (result.result == .ready)
            try self.view().captureAnchor(allocator)
        else
            null;
        defer if (final_anchor) |*anchor| anchor.deinit(allocator);

        var deferred = self.page.deferred_source_apply orelse {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        };
        if (deferred.mode != .canonical_publication or
            deferred.finished.generation != gate.source_generation)
        {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        }
        if (!self.sourceTerminalOwnsPending(&deferred.finished)) {
            self.abortCanonicalPublication(allocator);
            return .{ .skip_redraw = true };
        }
        const fingerprint = canonicalSourceFingerprint(&deferred);
        var prepared_source = self.prepareCanonicalSource(
            allocator,
            gate,
            &deferred,
        ) catch |err| {
            self.abortCanonicalPublication(allocator);
            return err;
        };
        defer prepared_source.deinit(allocator);

        const status_changes = gate.status.changesSnapshot();
        var prepared_tree = if (!source_changes and status_changes)
            self.prepareCanonicalCurrentTree(
                allocator,
                self.canonicalStatusDocument(gate),
            ) catch |err| {
                self.abortCanonicalPublication(allocator);
                return err;
            }
        else
            null;

        const outgoing_lineage = if (combined_reuse)
            self.installCanonicalCombinedReuse(allocator, result)
        else if (staged_only_reuse)
            self.installCanonicalStagedOnlyReuse(allocator, result)
        else
            null;

        gate.phase = .committing;
        const source_completion = self.page.action_cursor.captureCompletion(
            deferred.finished.identity.repo_epoch,
            .source,
            deferred.finished.generation,
        );
        var pending_reload = self.takeOwnedSourceTerminal(&deferred.finished) orelse unreachable;
        defer pending_reload.deinit(allocator);
        self.page.deferred_source_apply = null;

        if (source_changes or status_changes) {
            self.page.file_search.markProjectionUnavailable(allocator);
            self.page.accepted_sidebar_revision = file_search.nextAcceptedSidebarRevision(
                self.page.accepted_sidebar_revision,
            );
            self.page.review_projection.clearCache(allocator);
        }

        var retiring_status: ?git_status.GitStatusState = null;
        if (gate.status.takeReplacement()) |replacement| {
            retiring_status = self.page.git_status;
            self.page.git_status = replacement;
        }
        self.page.status_snapshot_revision = expected_status_revision;

        var retiring_load: ?load_state.LoadState = null;
        if (source_changes) {
            retiring_load = self.page.load.state;
            switch (prepared_source) {
                .loaded => |session| {
                    self.page.load.state = .{ .loaded = session };
                    prepared_source = .unchanged;
                },
                .empty => self.page.load.state = .{ .empty = .no_changes },
                .unchanged => unreachable,
            }
            self.page.source_session_revision = expected_source_revision;
        }
        if (prepared_tree) |*tree| self.installCanonicalCurrentTree(tree);
        if (reused) {
            // Exact comparison admitted the retained presentation before the
            // no-fail commit, but its lineage belongs to the final source and
            // status basis. Build the incoming token only after both live
            // owners and revisions name that canonical publication.
            self.finishExactPresentationTransfer(allocator, outgoing_lineage);
        }

        if (source_changes and final_anchor != null) {
            if (self.navigation.activeLoadedDiff()) |loaded| {
                _ = self.navigation.restoreReloadAnchor(loaded, &final_anchor.?);
            }
        }

        self.page.status_load.markSuccess();
        self.page.pending_initial_first_visible_selection = false;
        if (self.acceptSourceFingerprint(fingerprint)) |failure| {
            _ = self.page.status.clearSourceReloadFailure(failure.digest);
        }
        _ = self.page.activation.finishMember(
            deferred.finished.identity,
            .source,
            self.acceptedSourceMember(),
        );
        if (source_completion) |completion| {
            _ = self.page.action_cursor.finishCompletion(completion, true);
        }

        var result_transferred = reused;
        if (!reused) {
            self.clearCompletedSelectionForProjection(allocator, .{
                .repo_root = result.request.repo_root,
                .path_key = result.request.path_key,
            });
            self.page.staged_hunks.clear(allocator);
            self.page.review_projection.finishEagerRetry();
            self.page.review_projection.clearPending(allocator);
            self.page.review_projection.clearDisplayed(allocator);
            const request = result.request;
            result.request = undefined;
            switch (result.result) {
                .ready => |ready| {
                    result.result = undefined;
                    self.page.review_projection.installReady(.{
                        .request = request,
                        .value = ready,
                    });
                },
                .failed => |body| {
                    result.result = undefined;
                    self.page.review_projection.displayed = .{ .failed = .{
                        .request = request,
                        .body = body,
                    } };
                },
                .failed_static => {
                    const body = static_failure.?;
                    static_failure = null;
                    result.result = undefined;
                    self.page.review_projection.displayed = .{ .failed = .{
                        .request = request,
                        .body = body,
                    } };
                },
                .reuse_candidate, .staged_only_reuse_candidate => unreachable,
            }
            result_transferred = true;
        }

        _ = self.navigation.finalizeActionCursor(allocator);
        if (!reused) {
            if (final_anchor) |*anchor| {
                self.restoreDisplayedNavigation(anchor);
            } else {
                self.clearDisplayRestore(allocator);
            }
        }
        self.navigation.rebuildFileSearchProjection(allocator);

        if (retiring_load) |*state| deinitRetiringLoadState(state, allocator);
        if (retiring_status) |*status| status.deinit();
        if (deferred.cycle_id != 0) {
            self.page.auto_reload.finishMember(
                deferred.cycle_id,
                .deferred_source_apply,
            );
        }
        deferred.deinit(allocator);
        var finished_gate = self.page.canonical_publication.?;
        self.page.canonical_publication = null;
        finished_gate.deinit(allocator);
        return .{ .result_transferred = result_transferred };
    }

    /// Consumes a matching projection result into retained Review state. A
    /// true `result_transferred` means the caller must not deinitialize the
    /// task result: ordinary ready values move into the page, while an exact
    /// reuse candidate is split into retained authority and locally released
    /// comparison storage before the result is invalidated.
    pub fn applyProjectionFinished(
        self: Controller,
        allocator: std.mem.Allocator,
        result: *app_load.ReviewProjectionFinished,
    ) !ProjectionApply {
        const pending = if (self.page.review_projection.pending) |*request| request else return .{ .skip_redraw = true };
        if (pending.id != result.request.id or !pending.sameSemanticKey(result.request)) {
            return .{ .skip_redraw = true };
        }

        // Once a live-drag completion moves into the deferred slot, another
        // result with the same request identity is a duplicate, not the owner
        // of the still-retained page pending clone. The deferred apply removes
        // its slot before re-entering this function.
        if (self.page.deferred_projection_apply) |deferred| {
            if (deferred.finished.request.id == result.request.id and
                deferred.finished.request.sameSemanticKey(result.request))
            {
                return .{ .skip_redraw = true };
            }
        }

        if (self.page.canonical_publication) |gate| {
            if (gate.projection_request_id == result.request.id) {
                return self.applyCanonicalProjectionFinished(allocator, result);
            }
        }

        const publication_admitted = self.acceptsIdentity(result.request.identity) and
            self.page.repository_read_authority.acceptsRead(result.request.read_epoch);
        if (!publication_admitted) {
            return self.retireProjectionTerminalWithoutPublication(allocator);
        }

        const current = self.view().projectionTarget() orelse {
            return self.retireProjectionTerminalWithoutPublication(allocator);
        };
        if (result.request.kind == .generated_added_file and
            !result.request.matchesRootIdentity(self.root_identity))
        {
            return self.retireProjectionTerminalWithoutPublication(allocator);
        }
        if (!result.request.matchesBorrowed(
            self.page.repository_read_authority.epoch,
            current.repo_root,
            current.path_key,
            current.kind,
            current.source_kind,
            self.page.source_session_revision,
            self.page.status_snapshot_revision,
        )) {
            return self.retireProjectionTerminalWithoutPublication(allocator);
        }

        // Keep the pending request and displayed owner intact until the drag
        // transaction has copied its selection into owned memory. Only one
        // completion can match the single pending request; a duplicate is
        // rejected and remains the caller's cleanup responsibility.
        if (self.displayMutationBlockedByDrag()) {
            if (self.page.deferred_projection_apply != null) return .{ .skip_redraw = true };
            self.page.deferred_projection_apply = .{ .finished = result.* };
            return .{ .result_transferred = true, .skip_redraw = true };
        }

        if (result.result == .reuse_candidate) {
            return self.applyCombinedReuseCandidate(allocator, result);
        }
        if (result.result == .staged_only_reuse_candidate) {
            return self.applyStagedOnlyReuseCandidate(allocator, result);
        }

        // Anchor capture is the last fallible admission step before replacing
        // the retained display. If it fails, close this completed request but
        // keep the scalar eager-retry basis: prepareProjection can then issue
        // a fresh hint-free request instead of leaving a permanently pending
        // stale display. The caller still owns and cleans up `result`.
        var local_navigation = if (self.page.pending_display_navigation_restore == null)
            self.view().captureAnchor(allocator) catch |err| {
                self.page.review_projection.clearPending(allocator);
                return err;
            }
        else
            null;
        defer if (local_navigation) |*anchor| anchor.deinit(allocator);

        // A matching non-candidate terminal consumes the single eager retry
        // budget only after all fallible admission work succeeds. Failure
        // terminals remain terminal instead of scheduling another loop.
        self.page.review_projection.finishEagerRetry();

        const outgoing_lineage = self.currentPresentationLineageForPath(
            current.repo_root,
            current.path_key,
        );

        switch (result.result) {
            .ready => |*ready| {
                if (self.retainCombinedPresentationTokenIfExact(
                    current.repo_root,
                    current.path_key,
                    ready,
                )) |transfer| {
                    self.applyPresentationLineageTransfer(allocator, transfer);
                } else if (outgoing_lineage) |lineage| {
                    self.clearPresentationLineage(allocator, lineage);
                }
                self.reconcileCompletedSelectionForReady(allocator, .{
                    .repo_root = current.repo_root,
                    .path_key = current.path_key,
                }, ready);
            },
            .reuse_candidate, .staged_only_reuse_candidate => unreachable,
            .failed, .failed_static => {
                if (outgoing_lineage) |lineage| self.clearPresentationLineage(allocator, lineage);
                self.clearCompletedSelectionForProjection(allocator, .{
                    .repo_root = current.repo_root,
                    .path_key = current.path_key,
                });
            },
        }

        self.page.review_projection.clearPending(allocator);
        self.page.review_projection.cacheOrClearDisplayed(
            allocator,
            self.page.repository_read_authority.epoch,
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
            .reuse_candidate, .staged_only_reuse_candidate => unreachable,
            .failed_static => |message| {
                var request = try review_projection.cloneRequestWithOptions(
                    allocator,
                    result.request.identity,
                    result.request.id,
                    result.request.repo_root,
                    result.request.path_key,
                    result.request.kind,
                    result.request.source_kind,
                    result.request.source_session_revision,
                    result.request.status_snapshot_revision,
                    .{
                        .read_epoch = result.request.read_epoch,
                        .root_identity = result.request.root_identity,
                        .expected_presentation = result.request.expected_presentation,
                    },
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
    /// completion may already have advanced the session revision. The async
    /// delivery which filled this slot already skipped its redraw; this later
    /// call runs inside the input event which ended the borrow, whose redraw is
    /// still needed to remove or finalize the selection presentation.
    pub fn applyDeferredProjection(
        self: Controller,
        allocator: std.mem.Allocator,
    ) !void {
        var deferred = self.page.deferred_projection_apply orelse return;
        self.page.deferred_projection_apply = null;

        // Do not gate cleanup itself. `applyProjectionFinished` drains the
        // exact pending clone and uses `acceptsRead` (including the common open
        // predicate) to reject publication while a mutation owns the phase.
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
        const publication_admitted = !background_blocked and
            self.acceptsIdentity(finished.identity) and
            self.acceptsRepositoryReadCompletion(finished.read_epoch, finished.background_cycle_id);
        const owns_terminal = self.sourceTerminalOwnsPending(finished);
        var canonical_terminal = self.canonicalGateMatchesSource(finished);
        if (canonical_terminal and self.page.canonical_publication.?.status_generation == null) {
            var unpaired_gate = self.page.canonical_publication.?;
            self.page.canonical_publication = null;
            unpaired_gate.deinit(allocator);
            canonical_terminal = false;
        }
        if (canonical_terminal and (!owns_terminal or !publication_admitted)) {
            self.page.auto_reload.finishMember(finished.background_cycle_id, .source);
            self.abortCanonicalPublication(allocator);
            return .{ .redraw = .skip };
        }
        if (canonical_terminal and owns_terminal and publication_admitted) {
            switch (finished.result) {
                .empty, .unchanged, .loaded => {
                    if (self.page.deferred_source_apply != null) {
                        self.abortCanonicalPublication(allocator);
                        return .{ .redraw = .skip };
                    }
                    const cycle_id = finished.background_cycle_id orelse 0;
                    if (finished.background_cycle_id) |background_cycle_id| {
                        if (!self.page.auto_reload.moveMember(
                            background_cycle_id,
                            .source,
                            .deferred_source_apply,
                        )) {
                            self.abortCanonicalPublication(allocator);
                            return .{ .redraw = .skip };
                        }
                    }
                    self.page.deferred_source_apply = .{
                        .finished = finished.*,
                        .cycle_id = cycle_id,
                        .mode = .canonical_publication,
                    };
                    return .{ .result_transferred = true, .redraw = .skip };
                },
                .failed, .failed_static => {
                    self.page.auto_reload.finishMember(finished.background_cycle_id, .source);
                    var pending_reload = self.takeOwnedSourceTerminal(finished);
                    defer if (pending_reload) |*pending| pending.deinit(allocator);
                    _ = self.page.activation.finishMember(finished.identity, .source, .failed);
                    var outcome: SourceApply = .{
                        .redraw = .skip,
                        .terminal_admitted = true,
                    };
                    if (pending_reload != null and pending_reload.?.kind == .watch) {
                        const message = switch (finished.result) {
                            .failed => |value| std.mem.trim(u8, value, " \t\r\n"),
                            .failed_static => |value| value,
                            else => unreachable,
                        };
                        if (self.page.auto_reload.markSourceFailure(message)) {
                            outcome.auto_reload_failure = .{
                                .identity = self.page.auto_reload.last_failure.?,
                                .message = message,
                            };
                        }
                    }
                    self.abortCanonicalPublication(allocator);
                    return outcome;
                },
            }
        }
        if ((finished.result == .loaded or finished.result == .empty) and self.displayMutationBlockedByDrag() and
            owns_terminal and publication_admitted and self.page.deferred_source_apply == null)
        {
            if (finished.background_cycle_id) |cycle_id| {
                if (self.page.auto_reload.moveMember(cycle_id, .source, .deferred_source_apply)) {
                    self.page.deferred_source_apply = .{ .finished = finished.*, .cycle_id = cycle_id };
                    return .{ .result_transferred = true, .redraw = .skip };
                }
            }
        }
        self.page.auto_reload.finishMember(finished.background_cycle_id, .source);
        var pending_reload = self.takeOwnedSourceTerminal(finished);
        defer if (pending_reload) |*pending| pending.deinit(allocator);
        if (pending_reload == null or !publication_admitted) return .{ .redraw = .skip };

        const had_loaded_before = self.navigation.view().activeLoadedDiffConst() != null;
        const had_action_cursor = self.page.action_cursor.hasOwner();
        var can_project_status = false;
        var outcome: SourceApply = .{ .terminal_admitted = true };

        switch (finished.result) {
            .empty => {
                var acceptance_restore = if (pending_reload) |pending|
                    if (self.shouldCaptureAcceptanceRestore(pending.kind)) try self.view().captureDisplayRestore(allocator) else null
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
                        try self.applyStatusProjection(allocator, prefer_first, .accepted_source);
                        return outcome;
                    },
                    .rebuild_not_watch, .rebuild_no_current_loaded, .rebuild_text_changed => {},
                }

                var acceptance_restore = if (pending_reload) |pending|
                    if (self.shouldCaptureAcceptanceRestore(pending.kind))
                        try self.view().captureDisplayRestore(allocator)
                    else
                        null
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
                    } else if (self.page.action_cursor.hasRestoreAuthority()) {
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
                var failure = try self.applySourceFailure(allocator, pending_reload, std.mem.trim(u8, message, " \t\r\n"));
                failure.terminal_admitted = true;
                return failure;
            },
            .failed_static => |message| {
                _ = self.page.activation.finishMember(finished.identity, .source, .failed);
                var failure = try self.applySourceFailure(allocator, pending_reload, message);
                failure.terminal_admitted = true;
                return failure;
            },
        }

        const prefer_first = !had_loaded_before and !had_action_cursor;
        if (prefer_first and self.page.status_load.isPending()) self.page.pending_initial_first_visible_selection = true;
        if (can_project_status) try self.applyStatusProjection(allocator, prefer_first, .accepted_source);
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
        try self.replaceSourceFailure(allocator, message);
        return .{};
    }

    fn acceptSourceFingerprint(self: Controller, fingerprint: content_fingerprint.Fingerprint) ?auto_reload.FailureIdentity {
        const recovered_failure = self.page.auto_reload.last_failure;
        self.page.auto_reload.acceptSource(fingerprint);
        return recovered_failure;
    }

    /// Watch reloads always preserve acceptance-time navigation. Action
    /// reloads do so only after a later explicit sidebar selection has revoked
    /// the original action target; this captures the current user path before
    /// replacing the source arena.
    fn shouldCaptureAcceptanceRestore(self: Controller, kind: review_page.ReloadKind) bool {
        return kind == .watch or
            (kind == .action_result and self.page.action_cursor.hasOwner() and
                !self.page.action_cursor.hasRestoreAuthority());
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
        // Candidate paths borrow the accepted load arena. Revoke that complete
        // namespace before any source transition can free or replace it.
        self.page.advanceAcceptedSidebarRevision(allocator);
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
        // Status acceptance can replace sidebar target kinds, node indexes,
        // and active changed-file eligibility. Revoke the old candidate basis
        // before the status owner is committed; the later sidebar projection
        // republishes the retained query from the accepted model.
        self.page.advanceAcceptedSidebarRevision(allocator);
        if (allocator) |owner| {
            self.clearStatusInvalidatedCompletedSelection(owner);
            self.page.review_projection.clearCache(owner);
        } else {
            std.debug.assert(self.page.review_projection.cacheLen() == 0);
            if (self.page.completed_selection) |completed| switch (completed.token.display) {
                .loaded, .combined_projection => {},
                .cached_projection, .generated_untracked => unreachable,
            };
        }
        self.page.status_snapshot_revision +%= 1;
    }

    /// Replace the visible source with a prepared failure without allowing the
    /// low-level load-state commit to free an accepted sidebar owner directly.
    /// Preparing first preserves the current display if message allocation
    /// fails; an already-cleared caller does not advance revisions twice.
    pub fn replaceSourceFailure(self: Controller, allocator: std.mem.Allocator, message: []const u8) !void {
        var failed = try load_state.FailedLoad.init(allocator, message);
        if (self.page.load.state == .loaded) {
            self.clearSourceDisplay(allocator);
        } else {
            self.page.load.clearCurrent(allocator);
        }
        self.page.load.installPreparedFailed(&failed);
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

    pub fn applyStatusProjection(
        self: Controller,
        allocator: std.mem.Allocator,
        prefer_first_visible_file: bool,
        trigger: StatusProjectionTrigger,
    ) !void {
        const outcome = self.applyStatusProjectionPrimary(allocator, prefer_first_visible_file, trigger) catch |err| {
            // The accepted status/source transition remains authoritative even
            // when its derived sidebar or search projection cannot be built.
            self.page.file_search.markProjectionUnavailable(allocator);
            return err;
        };
        switch (outcome) {
            .current_sidebar => self.navigation.rebuildFileSearchProjection(allocator),
            .deferred_sidebar => self.page.file_search.markProjectionUnavailable(allocator),
        }
    }

    fn applyStatusProjectionPrimary(
        self: Controller,
        allocator: std.mem.Allocator,
        prefer_first_visible_file: bool,
        trigger: StatusProjectionTrigger,
    ) !StatusProjectionOutcome {
        if (!diff_source.sourceAllowsStageProjection(self.source)) return .current_sidebar;

        const status_document = self.page.git_status.document;
        const action_projection_deferred = self.page.action_cursor.hasOwner() and
            !self.page.action_cursor.terminal();
        if (status_document.entries.len == 0) {
            if (action_projection_deferred and
                (self.page.load.hasPending() or self.page.status_load.isPending())) return .deferred_sidebar;
            if (self.navigation.activeLoadedDiff()) |loaded| {
                if (loaded.document.files.len == 0) {
                    self.clearLoadedDiff(allocator);
                    self.page.load.replaceEmpty(allocator, .no_changes);
                    return if (action_projection_deferred) .deferred_sidebar else .current_sidebar;
                }
                if (action_projection_deferred) {
                    _ = self.navigation.remapActionCursor(loaded);
                    return .deferred_sidebar;
                }
                if (trigger != .accepted_source) {
                    // Empty status is authoritative after status acceptance
                    // and when an action pair reaches its terminal boundary.
                    // Rebuild so prior status-only rows cannot be reauthorized.
                    // Source acceptance alone already supplies a tree without
                    // status-only rows and keeps its navigation materialization.
                    try self.rebuildLoadedTreeWithStatus(allocator, loaded, prefer_first_visible_file);
                }
            }
            return if (action_projection_deferred) .deferred_sidebar else .current_sidebar;
        }

        if (self.navigation.activeLoadedDiff()) |loaded| {
            try self.rebuildLoadedTreeWithStatus(allocator, loaded, prefer_first_visible_file);
            return if (action_projection_deferred) .deferred_sidebar else .current_sidebar;
        }

        switch (self.page.load.state) {
            .empty => |reason| if (reason == .no_changes and
                file_tree.statusOnlyEntryCount(status_document, .{ .files = &.{} }) > 0)
            {
                try self.createStatusOnlyLoadedSession(allocator, status_document);
            },
            else => {},
        }
        return if (action_projection_deferred) .deferred_sidebar else .current_sidebar;
    }

    fn rebuildLoadedTreeWithStatus(
        self: Controller,
        app_allocator: std.mem.Allocator,
        loaded: *loaded_diff.LoadedDiff,
        prefer_first_visible_file: bool,
    ) !void {
        return self.rebuildLoadedTreeWithStatusDocument(
            app_allocator,
            loaded,
            self.page.git_status.document,
            prefer_first_visible_file,
        );
    }

    fn rebuildLoadedTreeWithStatusDocument(
        self: Controller,
        app_allocator: std.mem.Allocator,
        loaded: *loaded_diff.LoadedDiff,
        status_document: git_status.StatusDocument,
        prefer_first_visible_file: bool,
    ) !void {
        const allocator = self.navigation.loadArenaAllocator() orelse return;
        const previous_path_key = self.navigation.view().selectedStagePathKey();
        const previous_sidebar_identity = self.navigation.view().selectedSidebarIdentity();
        try self.navigation.ensureTreeOrderScope(app_allocator);
        loaded.tree = try file_tree.buildWithOptions(allocator, loaded.document, status_document, .{
            .root = self.navigation.view().fileTreeRootOptions(),
            .stable_order = self.navigation.stableOrderOptions(app_allocator),
        });
        try loaded.rebuildVisibleNodes(
            allocator,
            self.page.viewer.root_disclosure,
            self.page.review_display.hide_reviewed_files,
            self.page.review_display.changed_file_filter,
        );
        if (self.page.action_cursor.hasRestoreAuthority()) {
            _ = self.navigation.remapActionCursor(loaded);
            return;
        }
        // Source replacement can temporarily make the anchored path absent
        // until the fresh status snapshot is projected back into the tree.
        // Reapply that still-owned display anchor here, where a staged-only
        // row can finally satisfy it, and retain the anchor until the matching
        // projection result restores the body navigation.
        if (self.page.pending_display_navigation_restore) |*restore| {
            if (self.navigation.restoreReloadAnchor(loaded, restore.authoritative())) return;
        }
        if (prefer_first_visible_file) {
            self.navigation.selectFirstVisibleFile(loaded);
        } else {
            if (previous_path_key) |path_key| {
                if (navigation.findFileNodeByPathKey(loaded, path_key)) |node_index| {
                    self.navigation.selectSidebarNode(loaded, node_index);
                }
            }
            if (previous_sidebar_identity) |identity| {
                _ = self.navigation.restoreSidebarIdentity(loaded, identity);
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
        if (self.page.action_cursor.hasRestoreAuthority()) _ = self.navigation.remapActionCursor(active_loaded);
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

fn addTestSessionHunkMarks(
    page: *review_page.ReviewPageState,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    path_key: []const u8,
    content: review_selection.ReviewContentToken,
    ordinals: []const usize,
) !void {
    for (ordinals) |display_hunk_index| {
        try page.staged_hunks.addExact(allocator, repo_root, path_key, .{
            .content = content,
            .display_hunk_index = display_hunk_index,
        });
    }
}

fn expectTestSessionHunkMarks(
    page: *const review_page.ReviewPageState,
    repo_root: []const u8,
    path_key: []const u8,
    content: review_selection.ReviewContentToken,
    ordinals: []const usize,
) !void {
    for (ordinals) |display_hunk_index| {
        try std.testing.expect(page.staged_hunks.containsExact(repo_root, path_key, .{
            .content = content,
            .display_hunk_index = display_hunk_index,
        }));
    }
}

const test_combined_before_cached =
    \\diff --git a/a b/a
    \\index 1111111..2222222 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -3,1 +3,1 @@
    \\-const alpha: usize = 1;
    \\+const alpha: usize = 10;
    \\
;
const test_combined_before_unstaged =
    \\diff --git a/a b/a
    \\index 2222222..4444444 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -8,1 +8,1 @@
    \\-const beta: usize = 2;
    \\+const beta: usize = 20;
    \\@@ -13,1 +13,1 @@
    \\-const gamma: usize = 3;
    \\+const gamma: usize = 30;
    \\
;
const test_combined_primary =
    \\diff --git a/a b/a
    \\index 1111111..4444444 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -3,1 +3,1 @@
    \\-const alpha: usize = 1;
    \\+const alpha: usize = 10;
    \\@@ -8,1 +8,1 @@
    \\-const beta: usize = 2;
    \\+const beta: usize = 20;
    \\@@ -13,1 +13,1 @@
    \\-const gamma: usize = 3;
    \\+const gamma: usize = 30;
    \\
;
const test_combined_primary_changed =
    \\diff --git a/a b/a
    \\index 1111111..5555555 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -3,1 +3,1 @@
    \\-const alpha: usize = 1;
    \\+const alpha: usize = 10;
    \\@@ -8,1 +8,1 @@
    \\-const beta: usize = 2;
    \\+const beta: usize = 20;
    \\@@ -13,1 +13,1 @@
    \\-const gamma: usize = 3;
    \\+const gamma: usize = 31;
    \\
;
const test_multi_file_primary =
    \\diff --git a/b b/b
    \\index aaaaaaa..bbbbbbb 100644
    \\--- a/b
    \\+++ b/b
    \\@@ -1,1 +1,1 @@
    \\-const other: usize = 1;
    \\+const other: usize = 2;
    \\
++ test_combined_primary;
const test_combined_after_cached =
    \\diff --git a/a b/a
    \\index 1111111..3333333 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -3,1 +3,1 @@
    \\-const alpha: usize = 1;
    \\+const alpha: usize = 10;
    \\@@ -8,1 +8,1 @@
    \\-const beta: usize = 2;
    \\+const beta: usize = 20;
    \\
;
const test_combined_after_unstaged =
    \\diff --git a/a b/a
    \\index 3333333..4444444 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -13,1 +13,1 @@
    \\-const gamma: usize = 3;
    \\+const gamma: usize = 30;
    \\
;
const test_combined_changed_unstaged =
    \\diff --git a/a b/a
    \\index 3333333..5555555 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -13,1 +13,1 @@
    \\-const gamma: usize = 3;
    \\+const gamma: usize = 31;
    \\
;

fn testCombinedBundle(
    allocator: std.mem.Allocator,
    token_generation: u64,
    status_snapshot_revision: u64,
    cached_patch: []const u8,
    unstaged_patch: []const u8,
) !review_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, cached_patch);
    errdefer cached_bundle.deinit();
    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, unstaged_patch);
    errdefer unstaged_bundle.deinit();
    var cached_authority = try projection_component.ParsedComponent.parse(allocator, cached_patch);
    errdefer cached_authority.deinit();
    var unstaged_authority = try projection_component.ParsedComponent.parse(allocator, unstaged_patch);
    errdefer unstaged_authority.deinit();
    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer presentation_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );
    return .{
        .presentation = .{
            .arena = presentation_arena,
            .projection = projection.presentation,
            .cached_bundle = cached_bundle,
            .unstaged_bundle = unstaged_bundle,
            .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
            .content_token = .init(token_generation),
        },
        .authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached_authority,
            .unstaged_component = unstaged_authority,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
}

fn testCombinedReuseCandidate(
    allocator: std.mem.Allocator,
    status_snapshot_revision: u64,
    cached_patch: []const u8,
    unstaged_patch: []const u8,
) !review_projection.CombinedReuseCandidate {
    var cached = try projection_component.ParsedComponent.parse(allocator, cached_patch);
    errdefer cached.deinit();
    var unstaged = try projection_component.ParsedComponent.parse(allocator, unstaged_patch);
    errdefer unstaged.deinit();
    var candidate_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer candidate_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        candidate_arena.allocator(),
        authority_arena.allocator(),
        cached.document.files[0],
        unstaged.document.files[0],
    );
    const candidate: review_projection.CombinedReuseCandidate = .{
        .candidate_arena = candidate_arena,
        .projection = projection.presentation,
        .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
        .fresh_authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached,
            .unstaged_component = unstaged,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
    cached.arena = null;
    unstaged.arena = null;
    return candidate;
}

fn testStagedOnlyReuseCandidate(
    allocator: std.mem.Allocator,
    status_snapshot_revision: u64,
    cached_patch: []const u8,
) !review_projection.StagedOnlyReuseCandidate {
    var cached = try projection_component.ParsedComponent.parse(allocator, cached_patch);
    errdefer cached.deinit();
    if (cached.document.files.len != 1) return error.ExpectedSingleCachedFile;
    const owner = cached.arena.?.allocator();
    const hunk_count = cached.document.files[0].hunks.len;
    const stage_states = try owner.alloc(diff_hunk_projection.HunkStageState, hunk_count);
    @memset(stage_states, .staged);
    const action_origins = try owner.alloc(diff_hunk_projection.HunkActionOrigin, hunk_count);
    for (action_origins, 0..) |*origin, hunk_index| origin.* = .{ .cached = hunk_index };
    const candidate: review_projection.StagedOnlyReuseCandidate = .{
        .fingerprint = diff_presentation_identity.fingerprint(cached.document.files[0]),
        .fresh_authority = .{
            .projection = .{
                .hunk_stage_states = stage_states,
                .hunk_action_origins = action_origins,
            },
            .cached_component = cached,
            .status_snapshot_revision = status_snapshot_revision,
        },
    };
    cached.arena = null;
    return candidate;
}

fn testPrimaryLoadState(allocator: std.mem.Allocator, patch: []const u8) !load_state.LoadRuntimeState {
    var bundle = try app_load.buildLoadedBundle(allocator, patch);
    return .{ .state = .{ .loaded = .{
        .arena = bundle.takeArena(),
        .loaded = bundle.loaded,
    } } };
}

fn testPrimaryCombinedLoadState(allocator: std.mem.Allocator) !load_state.LoadRuntimeState {
    return testPrimaryLoadState(allocator, test_combined_primary);
}

fn testPrimaryCandidate(
    controller: Controller,
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
) !review_selection.CompletedSelection {
    return testPrimaryCandidateAt(controller, allocator, file, 1);
}

fn testPrimaryCandidateAt(
    controller: Controller,
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    line_index: usize,
) !review_selection.CompletedSelection {
    const token: review_selection.ReviewContentToken = .{
        .repo_epoch = controller.repo_epoch,
        .root_identity = controller.root_identity,
        .source = review_selection.SourceBasis.init(controller.source),
        .source_session_revision = controller.page.source_session_revision,
        .display = .{ .loaded = .init(controller.navigation.view().activeLoadedDiffConst().?.text) },
    };
    var drag = @import("../../../diff/selection.zig").DragSelection.init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = line_index },
    );
    drag.moved = true;
    return review_selection.buildParsed(allocator, token, file, drag);
}

fn testPrimaryCandidateForFile(
    controller: Controller,
    allocator: std.mem.Allocator,
    file_index: usize,
    line_index: usize,
) !review_selection.CompletedSelection {
    const loaded = controller.navigation.view().activeLoadedDiffConst() orelse
        return error.ExpectedLoadedDiff;
    if (file_index >= loaded.document.files.len) return error.ExpectedDiffFile;
    const file = loaded.document.files[file_index];
    const path_key = diff_file.canonicalPathKey(file) orelse return error.ExpectedPathKey;
    const token: review_selection.ReviewContentToken = .{
        .repo_epoch = controller.repo_epoch,
        .root_identity = controller.root_identity,
        .source = review_selection.SourceBasis.init(controller.source),
        .source_session_revision = controller.page.source_session_revision,
        .display = .{ .loaded = .init(loaded.text) },
    };
    var drag = @import("../../../diff/selection.zig").DragSelection.init(
        .{ .loaded_file = .{ .file_index = file_index, .path_key = path_key } },
        .new,
        .{ .hunk_index = 0, .line_index = line_index },
    );
    drag.moved = true;
    return review_selection.buildParsed(allocator, token, file, drag);
}

const TestProjectionSelectionOwner = enum {
    other_path,
    target_path,
};

const TestProjectionTerminal = enum {
    normal_ready,
    cache_hit,
    failed,
    failed_static,
    spawn_rejected,
    exact_candidate,
};

fn testMultiFileProjectionSelectionScope(
    allocator: std.mem.Allocator,
    owner: TestProjectionSelectionOwner,
    terminal: TestProjectionTerminal,
) !void {
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryLoadState(allocator, test_multi_file_primary),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const selection_file_index: usize = switch (owner) {
        .other_path => 0,
        .target_path => 1,
    };
    controller.navigation.setSelectedDiffFile(selection_file_index);
    page.completed_selection = try testPrimaryCandidateForFile(
        controller,
        allocator,
        selection_file_index,
        1,
    );
    const original_token = page.completed_selection.?.token;
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    controller.navigation.setSelectedDiffFile(1);

    switch (terminal) {
        .cache_hit => {
            page.review_projection.installReady(.{
                .request = try review_projection.testing.cloneRequest(
                    allocator,
                    page.activation.currentIdentity().?,
                    90,
                    "/repo",
                    "a",
                    .combined_hunks,
                    .unstaged,
                    page.source_session_revision,
                    page.status_snapshot_revision,
                ),
                .value = .{ .combined_hunks = try testCombinedBundle(
                    allocator,
                    90,
                    page.status_snapshot_revision,
                    test_combined_after_cached,
                    test_combined_changed_unstaged,
                ) },
            });
            page.review_projection.cacheOrClearDisplayed(
                allocator,
                .{},
                "/repo",
                .unstaged,
                page.source_session_revision,
                page.status_snapshot_revision,
            );
            try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());
            var update = try controller.prepareProjection(allocator);
            defer update.deinit(allocator);
            try std.testing.expect(update.command == null);
        },
        .normal_ready, .failed, .failed_static, .spawn_rejected, .exact_candidate => {
            var update = try controller.prepareProjection(allocator);
            defer update.deinit(allocator);
            if (terminal == .spawn_rejected) {
                const request_id = switch (update.command orelse return error.ExpectedProjectionCommand) {
                    .review_projection => |request| request.id,
                    else => return error.ExpectedProjectionCommand,
                };
                controller.rejectProjectionSpawn(allocator, request_id);
            } else {
                var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
                const request = switch (command) {
                    .review_projection => |request| request,
                    else => return error.ExpectedProjectionCommand,
                };
                command = undefined;
                switch (terminal) {
                    .normal_ready => {
                        var finished: app_load.ReviewProjectionFinished = .{
                            .request = request,
                            .result = .{ .ready = .{ .combined_hunks = try testCombinedBundle(
                                allocator,
                                request.id,
                                page.status_snapshot_revision,
                                test_combined_after_cached,
                                test_combined_changed_unstaged,
                            ) } },
                        };
                        const applied = try controller.applyProjectionFinished(allocator, &finished);
                        try std.testing.expect(applied.result_transferred);
                    },
                    .failed => {
                        var finished: app_load.ReviewProjectionFinished = .{
                            .request = request,
                            .result = .{ .failed = try review_projection.statusBodyAlloc(
                                allocator,
                                "a",
                                "{s}",
                                .{"failed"},
                            ) },
                        };
                        const applied = try controller.applyProjectionFinished(allocator, &finished);
                        try std.testing.expect(applied.result_transferred);
                    },
                    .failed_static => {
                        var finished: app_load.ReviewProjectionFinished = .{
                            .request = request,
                            .result = .{ .failed_static = "failed static" },
                        };
                        defer finished.deinit(allocator);
                        const applied = try controller.applyProjectionFinished(allocator, &finished);
                        try std.testing.expect(!applied.result_transferred);
                    },
                    .exact_candidate => {
                        var candidate = try testCombinedReuseCandidate(
                            allocator,
                            page.status_snapshot_revision,
                            test_combined_before_cached,
                            test_combined_before_unstaged,
                        );
                        var finished: app_load.ReviewProjectionFinished = .{
                            .request = request,
                            .result = .{ .reuse_candidate = candidate },
                        };
                        candidate = undefined;
                        const applied = try controller.applyProjectionFinished(allocator, &finished);
                        try std.testing.expect(applied.result_transferred);
                    },
                    .cache_hit, .spawn_rejected => unreachable,
                }
            }
        },
    }

    const should_survive = owner == .other_path or terminal == .exact_candidate;
    if (should_survive) {
        const completed = page.completed_selection orelse return error.ExpectedCompletedSelection;
        try std.testing.expectEqualStrings(if (owner == .other_path) "b" else "a", completed.pathKey());
        try std.testing.expect(completed.token.eql(original_token));
        const clipboard = try completed.clipboardText(allocator);
        defer allocator.free(clipboard);
        try std.testing.expectEqualStrings(original_clipboard, clipboard);
    } else {
        try std.testing.expect(page.completed_selection == null);
    }
}

test "projection lifecycle invalidates completed selection only for its target path" {
    const allocator = std.testing.allocator;
    const non_exact_terminals = [_]TestProjectionTerminal{
        .normal_ready,
        .cache_hit,
        .failed,
        .failed_static,
        .spawn_rejected,
    };
    for (non_exact_terminals) |terminal| {
        try testMultiFileProjectionSelectionScope(allocator, .other_path, terminal);
        try testMultiFileProjectionSelectionScope(allocator, .target_path, terminal);
    }
    try testMultiFileProjectionSelectionScope(allocator, .other_path, .exact_candidate);
    try testMultiFileProjectionSelectionScope(allocator, .target_path, .exact_candidate);
}

fn cloneTestProjectionRequest(
    allocator: std.mem.Allocator,
    request: review_projection.Request,
) !review_projection.Request {
    return review_projection.cloneRequestWithOptions(
        allocator,
        request.identity,
        request.id,
        request.repo_root,
        request.path_key,
        request.kind,
        request.source_kind,
        request.source_session_revision,
        request.status_snapshot_revision,
        .{
            .read_epoch = request.read_epoch,
            .root_identity = request.root_identity,
            .expected_presentation = request.expected_presentation,
        },
    );
}

fn testCombinedCandidate(
    controller: Controller,
    allocator: std.mem.Allocator,
    bundle: *const review_projection.CombinedHunkBundle,
) !review_selection.CompletedSelection {
    const ready: review_projection.Ready = .{ .combined_hunks = bundle.* };
    const token = controller.contentTokenForReady(&ready) orelse return error.ExpectedContentToken;
    var drag = @import("../../../diff/selection.zig").DragSelection.init(
        .{ .projection_file = .{ .kind = .combined, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 1 },
    );
    drag.moved = true;
    return review_selection.buildParsed(allocator, token, bundle.displayFile(), drag);
}

fn installTestCombinedCandidate(
    controller: Controller,
    allocator: std.mem.Allocator,
    request_id: u64,
    token_generation: u64,
    status_snapshot_revision: u64,
) !void {
    controller.page.review_projection.installReady(.{
        .request = try review_projection.testing.cloneRequest(
            allocator,
            controller.page.activation.currentIdentity().?,
            request_id,
            "/repo",
            "a",
            .combined_hunks,
            .unstaged,
            controller.page.source_session_revision,
            status_snapshot_revision,
        ),
        .value = .{ .combined_hunks = try testCombinedBundle(
            allocator,
            token_generation,
            status_snapshot_revision,
            test_combined_before_cached,
            test_combined_before_unstaged,
        ) },
    });
    const live = &controller.page.review_projection.displayed.ready.value.combined_hunks;
    controller.page.completed_selection = try testCombinedCandidate(controller, allocator, live);
}

fn installTestRetainedStagedOnly(
    controller: Controller,
    allocator: std.mem.Allocator,
    request_id: u64,
    token_generation: u64,
    status_snapshot_revision: u64,
) !void {
    try installTestCombinedCandidate(
        controller,
        allocator,
        request_id,
        token_generation,
        status_snapshot_revision,
    );
    var candidate = try testStagedOnlyReuseCandidate(
        allocator,
        status_snapshot_revision,
        test_combined_primary,
    );
    defer candidate.deinit();
    const request = try review_projection.testing.cloneRequest(
        allocator,
        controller.page.activation.currentIdentity().?,
        request_id + 1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        controller.page.source_session_revision,
        status_snapshot_revision,
    );
    controller.page.review_projection.installRetainedStagedOnlyReuse(
        allocator,
        request,
        &candidate,
    );
}

fn installTestPrimaryStagedOnly(
    controller: Controller,
    allocator: std.mem.Allocator,
    request_id: u64,
    status_snapshot_revision: u64,
) !void {
    var combined = try testCombinedReuseCandidate(
        allocator,
        status_snapshot_revision,
        test_combined_before_cached,
        test_combined_before_unstaged,
    );
    defer combined.deinit();
    controller.page.review_projection.installReady(.{
        .request = try review_projection.testing.cloneRequest(
            allocator,
            controller.page.activation.currentIdentity().?,
            request_id,
            "/repo",
            "a",
            .combined_hunks,
            .unstaged,
            controller.page.source_session_revision,
            status_snapshot_revision,
        ),
        .value = .{ .primary_combined_authority = combined.discardCandidateAndTakeAuthority() },
    });

    var staged_only = try testStagedOnlyReuseCandidate(
        allocator,
        status_snapshot_revision,
        test_combined_primary,
    );
    defer staged_only.deinit();
    const request = try review_projection.testing.cloneRequest(
        allocator,
        controller.page.activation.currentIdentity().?,
        request_id + 1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        controller.page.source_session_revision,
        status_snapshot_revision,
    );
    controller.page.review_projection.installPrimaryStagedOnlyReuse(
        allocator,
        request,
        &staged_only,
    );
}

fn applyTestCombinedBundle(
    controller: Controller,
    allocator: std.mem.Allocator,
    request_id: u64,
    status_snapshot_revision: u64,
    bundle: review_projection.CombinedHunkBundle,
) !void {
    var owned_bundle = bundle;
    var bundle_owned = true;
    errdefer if (bundle_owned) owned_bundle.deinit();
    try std.testing.expectEqual(status_snapshot_revision, controller.page.status_snapshot_revision);
    controller.page.review_projection.pending = try review_projection.testing.cloneRequest(
        allocator,
        controller.page.activation.currentIdentity().?,
        request_id,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        controller.page.source_session_revision,
        status_snapshot_revision,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.testing.cloneRequest(
            allocator,
            controller.page.activation.currentIdentity().?,
            request_id,
            "/repo",
            "a",
            .combined_hunks,
            .unstaged,
            controller.page.source_session_revision,
            status_snapshot_revision,
        ),
        .result = .{ .ready = .{ .combined_hunks = owned_bundle } },
    };
    bundle_owned = false;
    owned_bundle = undefined;
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;
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
    var request = try review_projection.testing.cloneRequest(
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
        .read_epoch = .{},
        .request = try diff_source.cloneLoadRequest(allocator, .{ .source = .{ .range = "main...HEAD" }, .repo_root = "/repo" }),
        .generation = 1,
        .expected_fingerprint = null,
        .background_cycle_id = null,
    } } };
    source_update.deinit(allocator);

    var status_update: ReviewUpdate = .{ .command = .{ .status_load = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .read_epoch = .{},
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 2,
        .origin = .foreground,
        .background_cycle_id = null,
    } } };
    status_update.deinit(allocator);

    var branch_update: ReviewUpdate = .{ .command = .{ .branch_status_load = .{
        .identity = app_page.RequestIdentity.review(0, 1),
        .read_epoch = .{},
        .repo_root = try allocator.dupe(u8, "/repo"),
        .generation = 3,
        .background_cycle_id = null,
    } } };
    branch_update.deinit(allocator);

    var projection_update: ReviewUpdate = .{ .command = .{ .review_projection = try review_projection.testing.cloneRequest(
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

test "review read epoch is captured by source status and branch commands" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    page.repository_read_authority.epoch = .{ .value = 41 };
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    {
        var update = try controller.prepareSourceLoad(
            allocator,
            "/repo",
            .{ .clear_visible_state = false, .kind = .manual },
        );
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedSourceCommand;
        defer command.deinit(allocator);
        try std.testing.expect(command.source_load.read_epoch.eql(.{ .value = 41 }));
        try std.testing.expect(page.pending_reload.?.read_epoch.eql(.{ .value = 41 }));
    }

    {
        var update = try controller.prepareStatusLoad(allocator, "/repo", .foreground, null);
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedStatusCommand;
        defer command.deinit(allocator);
        try std.testing.expect(command.status_load.read_epoch.eql(.{ .value = 41 }));
        try std.testing.expect(page.status_load.pending.?.read_epoch.eql(.{ .value = 41 }));
    }

    {
        var update = try controller.prepareBranchStatusLoad(allocator, "/repo", null);
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedBranchCommand;
        defer command.deinit(allocator);
        try std.testing.expect(command.branch_status_load.read_epoch.eql(.{ .value = 41 }));
        try std.testing.expect(page.branch_status_load.pending.?.read_epoch.eql(.{ .value = 41 }));
    }
}

test "mutation read start gate rejects every repository read preparation without changing owners" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    _ = page.activation.activate(0, .fresh, .fresh, .fresh);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const owner: app_actions.PendingAction = .{
        .generation = 51,
        .kind = .stage_hunk,
    };
    try std.testing.expect(page.repository_read_authority.closeForMutation(owner));

    try std.testing.expectError(
        error.RepositoryReadAuthorityClosed,
        controller.prepareSourceLoad(
            allocator,
            "/repo",
            .{ .clear_visible_state = true, .kind = .manual },
        ),
    );
    try std.testing.expectError(
        error.RepositoryReadAuthorityClosed,
        controller.prepareRepoDiscovery(allocator, null),
    );
    try std.testing.expectError(
        error.RepositoryReadAuthorityClosed,
        controller.prepareStatusLoad(allocator, "/repo", .foreground, null),
    );
    try std.testing.expectError(
        error.RepositoryReadAuthorityClosed,
        controller.prepareBranchStatusLoad(allocator, "/repo", null),
    );

    try std.testing.expect(page.load.state == .idle);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
    try std.testing.expectEqual(@as(u64, 0), page.load.generation);
    try std.testing.expect(page.status_load.pending == null);
    try std.testing.expectEqual(@as(u64, 0), page.status_load.generation);
    try std.testing.expect(page.branch_status_load.pending == null);
    try std.testing.expectEqual(@as(u64, 0), page.branch_status_load.generation);
    const active = page.activation.state.active;
    try std.testing.expectEqual(authority.MemberFreshness.fresh, active.members.source);
    try std.testing.expectEqual(authority.MemberFreshness.fresh, active.members.status);
    try std.testing.expectEqual(authority.MemberFreshness.fresh, active.members.branch);
}

test "repository read completion admission requires current open epoch and cycle" {
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(std.testing.allocator);
    page.repository_read_authority.epoch = .{ .value = 11 };
    page.auto_reload = .init(.inherit, .{}, .unstaged);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try std.testing.expect(controller.acceptsRepositoryReadCompletion(.{ .value = 11 }, null));
    try std.testing.expect(!controller.acceptsRepositoryReadCompletion(.{ .value = 10 }, null));

    const cycle_id = page.auto_reload.beginCycle().?;
    try std.testing.expect(page.auto_reload.markMemberStarted(cycle_id, .source));
    try std.testing.expect(controller.acceptsRepositoryReadCompletion(.{ .value = 11 }, cycle_id));
    page.auto_reload.supersedeActiveCycleByMutation();
    try std.testing.expect(!controller.acceptsRepositoryReadCompletion(.{ .value = 11 }, cycle_id));
    page.auto_reload.finishMember(cycle_id, .source);

    page.repository_read_authority.phase = .{ .mutation_in_flight = .{
        .generation = 7,
        .kind = .stage_hunk,
    } };
    try std.testing.expect(!controller.acceptsRepositoryReadCompletion(.{ .value = 11 }, null));
}

fn expectMutationFenceRetainedReadOwners(
    page: *const review_page.ReviewPageState,
    source_generation: u64,
    read_epoch: ReviewRepositoryReadEpoch,
    cycle_id: u64,
    anchor_path_ptr: [*]const u8,
    status_pending: auto_reload.AuxiliaryPending,
    branch_pending: auto_reload.AuxiliaryPending,
    cache_len: usize,
    cache_retained_bytes: usize,
) !void {
    try std.testing.expect(std.meta.eql(
        page.load.pending orelse return error.ExpectedSourcePending,
        load_state.PendingLoad{ .diff_load = source_generation },
    ));
    const pending_reload = page.pending_reload orelse return error.ExpectedPendingReload;
    try std.testing.expectEqual(source_generation, pending_reload.generation);
    try std.testing.expect(pending_reload.read_epoch.eql(read_epoch));
    try std.testing.expectEqual(review_page.ReloadKind.watch, pending_reload.kind);
    const anchor = pending_reload.anchor orelse return error.ExpectedReloadAnchor;
    try std.testing.expectEqual(anchor_path_ptr, @as([*]const u8, anchor.path_key.ptr));
    try std.testing.expect(std.meta.eql(
        status_pending,
        page.status_load.pending orelse return error.ExpectedStatusPending,
    ));
    try std.testing.expect(std.meta.eql(
        branch_pending,
        page.branch_status_load.pending orelse return error.ExpectedBranchPending,
    ));
    const cycle = page.auto_reload.background_cycle orelse return error.ExpectedBackgroundCycle;
    try std.testing.expectEqual(cycle_id, cycle.id);
    try std.testing.expect(cycle.pending.owns(.source));
    try std.testing.expect(cycle.pending.owns(.status));
    try std.testing.expect(cycle.pending.owns(.branch));
    try std.testing.expect(!cycle.pending.owns(.deferred_source_apply));
    try std.testing.expectEqual(cache_len, page.review_projection.cacheLen());
    try std.testing.expectEqual(cache_retained_bytes, page.review_projection.cacheRetainedBytes());
    try std.testing.expect(page.review_projection.cacheHas(
        read_epoch,
        "/repo",
        "cached",
        .generated_added_file,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
    ));
}

test "mutation read fence closes one exact owner and preserves read drain ownership" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    page.auto_reload = .init(.inherit, .{}, .unstaged);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const identity = page.activation.currentIdentity().?;
    const root_identity: root_capability.Identity = .{ .device = 11, .inode = 17 };
    const old_epoch = page.repository_read_authority.epoch;

    const cycle_id = page.auto_reload.beginCycle().?;
    var source_update = try controller.prepareSourceLoad(allocator, "/repo", .{
        .clear_visible_state = false,
        .kind = .watch,
        .background_cycle_id = cycle_id,
    });
    defer source_update.deinit(allocator);
    var source_command_owner = source_update.takeCommand() orelse return error.ExpectedSourceCommand;
    defer source_command_owner.deinit(allocator);
    const source_command = switch (source_command_owner) {
        .source_load => |command| command,
        else => return error.ExpectedSourceCommand,
    };
    controller.acceptSourceSpawn(cycle_id);

    var status_update = try controller.prepareStatusLoad(allocator, "/repo", .background, cycle_id);
    defer status_update.deinit(allocator);
    var status_command_owner = status_update.takeCommand() orelse return error.ExpectedStatusCommand;
    defer status_command_owner.deinit(allocator);
    const status_command = switch (status_command_owner) {
        .status_load => |command| command,
        else => return error.ExpectedStatusCommand,
    };
    controller.acceptStatusSpawn(cycle_id);

    var branch_update = try controller.prepareBranchStatusLoad(allocator, "/repo", cycle_id);
    defer branch_update.deinit(allocator);
    var branch_command_owner = branch_update.takeCommand() orelse return error.ExpectedBranchCommand;
    defer branch_command_owner.deinit(allocator);
    const branch_command = switch (branch_command_owner) {
        .branch_status_load => |command| command,
        else => return error.ExpectedBranchCommand,
    };
    controller.acceptBranchStatusSpawn(cycle_id);

    const pending_reload = page.pending_reload orelse return error.ExpectedPendingReload;
    const anchor_path_ptr = @as([*]const u8, (pending_reload.anchor orelse return error.ExpectedReloadAnchor).path_key.ptr);
    const status_pending = page.status_load.pending orelse return error.ExpectedStatusPending;
    const branch_pending = page.branch_status_load.pending orelse return error.ExpectedBranchPending;

    page.review_projection.installReady(try testGeneratedReady(
        allocator,
        9,
        "cached",
        page.source_session_revision,
        page.status_snapshot_revision,
    ));
    page.review_projection.cacheOrClearDisplayed(
        allocator,
        old_epoch,
        "/repo",
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
    );
    const cache_len = page.review_projection.cacheLen();
    const cache_retained_bytes = page.review_projection.cacheRetainedBytes();
    try std.testing.expectEqual(@as(usize, 1), cache_len);
    try std.testing.expect(cache_retained_bytes > 0);

    var displayed_request = try review_projection.cloneRequestWithOptions(
        allocator,
        identity,
        1,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
        .{ .read_epoch = old_epoch, .root_identity = root_identity },
    );
    var displayed_request_owned = true;
    defer if (displayed_request_owned) displayed_request.deinit(allocator);
    var displayed_bundle = try review_projection.generatedFileFromContent(allocator, "a", "one\ntwo\n");
    var displayed_bundle_owned = true;
    defer if (displayed_bundle_owned) displayed_bundle.deinit(allocator);
    page.review_projection.installReady(.{
        .request = displayed_request,
        .value = .{ .generated_added_file = displayed_bundle },
    });
    displayed_request_owned = false;
    displayed_bundle_owned = false;
    displayed_request = undefined;
    displayed_bundle = undefined;
    const displayed_source = page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr;

    page.review_projection.syntax_pending = try review_projection.generatedSyntaxRequestForProjection(
        allocator,
        1,
        identity,
        page.review_projection.displayed.ready.request,
        page.review_projection.displayed.ready.value.generated_added_file.fingerprint(),
    );
    page.review_projection.pending = try review_projection.cloneRequestWithOptions(
        allocator,
        identity,
        2,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
        .{ .read_epoch = old_epoch, .root_identity = root_identity },
    );
    page.deferred_projection_apply = .{ .finished = .{
        .request = try cloneTestProjectionRequest(allocator, page.review_projection.pending.?),
        .result = .{ .failed_static = "pre-mutation result" },
    } };

    const assistance: app_actions.PendingAction = .{
        .generation = 6,
        .kind = .assist_commit_message,
    };
    try std.testing.expect(!controller.beginMutationReadFence(allocator, assistance));
    try std.testing.expect(page.repository_read_authority.epoch.eql(old_epoch));
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expect(page.review_projection.syntax_pending != null);
    try std.testing.expect(page.deferred_projection_apply != null);
    try std.testing.expect(page.auto_reload.acceptsCycle(cycle_id));
    try expectMutationFenceRetainedReadOwners(
        &page,
        source_command.generation,
        old_epoch,
        cycle_id,
        anchor_path_ptr,
        status_pending,
        branch_pending,
        cache_len,
        cache_retained_bytes,
    );

    const mutation: app_actions.PendingAction = .{
        .generation = 7,
        .kind = .stage_hunk,
    };
    try std.testing.expect(controller.beginMutationReadFence(allocator, mutation));
    const fenced_epoch = page.repository_read_authority.epoch;
    try std.testing.expect(fenced_epoch.eql(old_epoch.next()));
    try std.testing.expect(page.repository_read_authority.ownsMutation(mutation));
    try std.testing.expect(!page.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.syntax_pending == null);
    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(page.review_projection.hasDisplayed());
    try std.testing.expectEqual(
        displayed_source,
        page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr,
    );
    try std.testing.expectEqual(
        auto_reload.CycleAcceptance.superseded_by_mutation,
        page.auto_reload.background_cycle.?.acceptance,
    );
    try std.testing.expect(!page.auto_reload.acceptsCycle(cycle_id));
    try expectMutationFenceRetainedReadOwners(
        &page,
        source_command.generation,
        old_epoch,
        cycle_id,
        anchor_path_ptr,
        status_pending,
        branch_pending,
        cache_len,
        cache_retained_bytes,
    );

    try std.testing.expect(!controller.beginMutationReadFence(allocator, mutation));
    try std.testing.expect(page.repository_read_authority.epoch.eql(fenced_epoch));
    try expectMutationFenceRetainedReadOwners(
        &page,
        source_command.generation,
        old_epoch,
        cycle_id,
        anchor_path_ptr,
        status_pending,
        branch_pending,
        cache_len,
        cache_retained_bytes,
    );

    var source_finished: app_load.DiffLoadFinished = .{
        .identity = source_command.identity,
        .read_epoch = source_command.read_epoch,
        .generation = source_command.generation,
        .background_cycle_id = cycle_id,
        .result = .{ .failed_static = "must not publish source" },
    };
    defer source_finished.deinit(allocator);
    const source_applied = try controller.applySourceFinished(allocator, &source_finished, false);
    try std.testing.expect(!source_applied.terminal_admitted);
    try std.testing.expectEqual(RedrawDisposition.skip, source_applied.redraw);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
    try std.testing.expect(page.auto_reload.background_cycle != null);

    var status_finished: app_load.StatusLoadFinished = .{
        .identity = status_command.identity,
        .read_epoch = status_command.read_epoch,
        .generation = status_command.generation,
        .background_cycle_id = cycle_id,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "must not publish status" },
    };
    defer status_finished.deinit(allocator);
    const status_applied = try controller.applyStatusFinished(allocator, &status_finished, false);
    try std.testing.expect(!status_applied.terminal_admitted);
    try std.testing.expect(status_applied.skip_redraw);
    try std.testing.expect(page.status_load.pending == null);
    try std.testing.expect(page.auto_reload.background_cycle != null);

    var branch_finished: app_load.BranchStatusLoadFinished = .{
        .identity = branch_command.identity,
        .read_epoch = branch_command.read_epoch,
        .generation = branch_command.generation,
        .background_cycle_id = cycle_id,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "must not publish branch" },
    };
    defer branch_finished.deinit(allocator);
    const branch_applied = controller.applyBranchStatusFinished(&branch_finished, false);
    try std.testing.expect(!branch_applied.terminal_admitted);
    try std.testing.expect(branch_applied.skip_redraw);
    try std.testing.expect(page.branch_status_load.pending == null);
    try std.testing.expect(page.auto_reload.background_cycle == null);
    try std.testing.expectEqual(cache_len, page.review_projection.cacheLen());
    try std.testing.expectEqual(cache_retained_bytes, page.review_projection.cacheRetainedBytes());
    try std.testing.expect(page.review_projection.cacheHas(
        old_epoch,
        "/repo",
        "cached",
        .generated_added_file,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
    ));
    try std.testing.expectEqual(
        displayed_source,
        page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr,
    );
}

test "mutation read fence retains deferred source until production apply drains it" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    page.auto_reload = .init(.inherit, .{}, .unstaged);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const old_epoch = page.repository_read_authority.epoch;
    const cycle_id = page.auto_reload.beginCycle().?;

    var update = try controller.prepareSourceLoad(allocator, "/repo", .{
        .clear_visible_state = false,
        .kind = .watch,
        .background_cycle_id = cycle_id,
    });
    defer update.deinit(allocator);
    var command_owner = update.takeCommand() orelse return error.ExpectedSourceCommand;
    defer command_owner.deinit(allocator);
    const command = switch (command_owner) {
        .source_load => |source| source,
        else => return error.ExpectedSourceCommand,
    };
    controller.acceptSourceSpawn(cycle_id);

    page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var finished: app_load.DiffLoadFinished = .{
        .identity = command.identity,
        .read_epoch = command.read_epoch,
        .generation = command.generation,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, test_support.diff_unstaged_projection) },
    };
    const deferred_payload_ptr = finished.result.loaded.loaded.text.ptr;
    const deferred = try controller.applySourceFinished(allocator, &finished, false);
    try std.testing.expect(deferred.result_transferred);
    finished = undefined;

    const pending_reload = page.pending_reload orelse return error.ExpectedPendingReload;
    const anchor_path_ptr = @as([*]const u8, (pending_reload.anchor orelse return error.ExpectedReloadAnchor).path_key.ptr);
    const deferred_before = page.deferred_source_apply orelse return error.ExpectedDeferredSource;
    try std.testing.expectEqual(cycle_id, deferred_before.cycle_id);
    try std.testing.expectEqual(command.generation, deferred_before.finished.generation);
    try std.testing.expect(deferred_before.finished.read_epoch.eql(old_epoch));
    try std.testing.expectEqual(deferred_payload_ptr, deferred_before.finished.result.loaded.loaded.text.ptr);
    try std.testing.expect(!page.auto_reload.background_cycle.?.pending.owns(.source));
    try std.testing.expect(page.auto_reload.background_cycle.?.pending.owns(.deferred_source_apply));

    const mutation: app_actions.PendingAction = .{
        .generation = 8,
        .kind = .unstage_hunk,
    };
    try std.testing.expect(controller.beginMutationReadFence(allocator, mutation));
    const retained = page.deferred_source_apply orelse return error.ExpectedDeferredSource;
    try std.testing.expectEqual(cycle_id, retained.cycle_id);
    try std.testing.expectEqual(command.generation, retained.finished.generation);
    try std.testing.expect(retained.finished.read_epoch.eql(old_epoch));
    try std.testing.expectEqual(deferred_payload_ptr, retained.finished.result.loaded.loaded.text.ptr);
    try std.testing.expectEqual(
        anchor_path_ptr,
        @as([*]const u8, page.pending_reload.?.anchor.?.path_key.ptr),
    );
    try std.testing.expectEqual(
        auto_reload.CycleAcceptance.superseded_by_mutation,
        page.auto_reload.background_cycle.?.acceptance,
    );
    try std.testing.expect(page.auto_reload.background_cycle.?.pending.owns(.deferred_source_apply));

    page.selection_owner = .none;
    var applied = (try controller.applyDeferredSource(allocator, false)) orelse return error.ExpectedDeferredApply;
    defer applied.deinit(allocator);
    try std.testing.expect(!applied.source.terminal_admitted);
    try std.testing.expectEqual(RedrawDisposition.skip, applied.source.redraw);
    try std.testing.expect(page.deferred_source_apply == null);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
    try std.testing.expect(page.auto_reload.background_cycle == null);
}

test "mutation read fence terminal reopens exact owner and queues active revalidation" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    const activation_id = page.activation.activate(13, .fresh, .fresh, .fresh);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const old_epoch = page.repository_read_authority.epoch;
    const owner: app_actions.PendingAction = .{
        .generation = 21,
        .kind = .stage_hunk,
    };

    try std.testing.expect(!controller.finishMutationReadFence(.{
        .generation = 20,
        .kind = .assist_commit_message,
    }));
    try std.testing.expect(page.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(page.activation.revalidation_requested == null);

    try std.testing.expect(controller.beginMutationReadFence(allocator, owner));
    const fenced_epoch = page.repository_read_authority.epoch;
    try std.testing.expect(fenced_epoch.eql(old_epoch.next()));
    try std.testing.expect(!page.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(page.activation.revalidation_requested == null);

    try std.testing.expect(!controller.finishMutationReadFence(.{
        .generation = 20,
        .kind = .stage_hunk,
    }));
    try std.testing.expect(!controller.finishMutationReadFence(.{
        .generation = owner.generation,
        .kind = .unstage_hunk,
    }));
    try std.testing.expect(page.repository_read_authority.ownsMutation(owner));
    try std.testing.expect(page.repository_read_authority.epoch.eql(fenced_epoch));
    try std.testing.expect(page.activation.revalidation_requested == null);

    try std.testing.expect(controller.finishMutationReadFence(owner));
    try std.testing.expect(page.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(page.repository_read_authority.epoch.eql(fenced_epoch));
    try std.testing.expectEqual(
        activation_id,
        page.activation.action_terminal_revalidation_requested orelse
            return error.ExpectedRevalidationIntent,
    );
    try std.testing.expect(page.activation.revalidation_requested == null);
    try std.testing.expect(page.activation.hasQueuedFullRevalidation());
    page.activation.consumeAcceptedFullRevalidation();
    try std.testing.expect(!page.activation.hasQueuedFullRevalidation());

    const later_activation = page.activation.activate(13, .fresh, .fresh, .fresh);
    try std.testing.expect(later_activation != activation_id);
    try std.testing.expect(!controller.finishMutationReadFence(owner));
    try std.testing.expect(page.activation.revalidation_requested == null);
    try std.testing.expect(page.activation.action_terminal_revalidation_requested == null);
}

test "mutation read fence terminal coalesces current intent and never targets a future activation" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    const activation_id = page.activation.activate(17, .fresh, .fresh, .fresh);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const first: app_actions.PendingAction = .{
        .generation = 31,
        .kind = .unstage_hunk,
    };

    page.activation.queueRevalidation();
    try std.testing.expectEqual(
        activation_id,
        page.activation.revalidation_requested orelse return error.ExpectedRevalidationIntent,
    );
    try std.testing.expect(controller.beginMutationReadFence(allocator, first));
    try std.testing.expect(controller.finishMutationReadFence(first));
    try std.testing.expectEqual(
        activation_id,
        page.activation.revalidation_requested orelse return error.ExpectedRevalidationIntent,
    );
    try std.testing.expectEqual(
        activation_id,
        page.activation.action_terminal_revalidation_requested orelse
            return error.ExpectedTerminalRevalidationIntent,
    );
    try std.testing.expect(page.activation.hasQueuedFullRevalidation());
    page.activation.consumeAcceptedFullRevalidation();
    try std.testing.expect(!page.activation.hasQueuedFullRevalidation());

    const second: app_actions.PendingAction = .{
        .generation = 32,
        .kind = .stage_file,
    };
    try std.testing.expect(controller.beginMutationReadFence(allocator, second));
    const fenced_epoch = page.repository_read_authority.epoch;
    page.activation.deactivate();

    try std.testing.expect(controller.finishMutationReadFence(second));
    try std.testing.expect(page.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(page.repository_read_authority.epoch.eql(fenced_epoch));
    try std.testing.expect(page.activation.revalidation_requested == null);
    try std.testing.expect(page.activation.action_terminal_revalidation_requested == null);

    _ = page.activation.activate(17, .fresh, .fresh, .fresh);
    try std.testing.expect(page.activation.revalidation_requested == null);
    try std.testing.expect(!controller.finishMutationReadFence(second));
    try std.testing.expect(page.activation.revalidation_requested == null);
    try std.testing.expect(page.activation.action_terminal_revalidation_requested == null);
}

test "mutation read promotion gate retains current visual and cache owners until reopen" {
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 41, .inode = 43 };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00?? b\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    var controller = testController(&page, &status_message, .unstaged);
    controller.root_identity = root;

    const owner: app_actions.PendingAction = .{
        .generation = 44,
        .kind = .stage_file,
    };
    try std.testing.expect(page.repository_read_authority.closeForMutation(owner));
    const fenced_epoch = page.repository_read_authority.epoch;

    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            page.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{ .read_epoch = fenced_epoch, .root_identity = root },
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "cached\n") },
    });
    const cached_source = page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr;
    page.review_projection.cacheOrClearDisplayed(allocator, fenced_epoch, "/repo", .unstaged, 0, 0);

    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            page.activation.currentIdentity().?,
            2,
            "/repo",
            "b",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{ .read_epoch = fenced_epoch, .root_identity = root },
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "b", "retained\n") },
    });
    const retained_source = page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr;

    var blocked = try controller.prepareProjection(allocator);
    defer blocked.deinit(allocator);
    try std.testing.expect(blocked.command == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expectEqual(retained_source, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
    try std.testing.expect(page.review_projection.cacheHas(
        fenced_epoch,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        0,
        0,
    ));

    try std.testing.expect(page.repository_read_authority.reopenForMutation(owner));
    var promoted = try controller.prepareProjection(allocator);
    defer promoted.deinit(allocator);
    try std.testing.expect(promoted.command == null);
    try std.testing.expectEqual(cached_source, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
}

test "mutation read promotion gate blocks generated syntax preparation until reopen" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 47, .inode = 53 };
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

    const owner: app_actions.PendingAction = .{
        .generation = 54,
        .kind = .unstage_file,
    };
    try std.testing.expect(page.repository_read_authority.closeForMutation(owner));
    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            page.activation.currentIdentity().?,
            3,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{
                .read_epoch = page.repository_read_authority.epoch,
                .root_identity = root,
            },
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(
            allocator,
            "a",
            "const value = 1;\n",
        ) },
    });

    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
    try std.testing.expect(page.review_projection.displayed.ready.value.generated_added_file.decoration == .eligible);

    try std.testing.expect(page.repository_read_authority.reopenForMutation(owner));
    var request = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRequest;
    defer request.deinit(allocator);
    try std.testing.expect(page.review_projection.hasSyntaxPending());
    controller.rejectGeneratedSyntaxSpawn(allocator, request.id);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
}

test "old repository read source terminal retires ownership without publication" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    const retained_text = controller.navigation.view().activeLoadedDiffConst().?.text.ptr;

    var update = try controller.prepareSourceLoad(
        allocator,
        "/repo",
        .{ .clear_visible_state = false, .kind = .manual },
    );
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedSourceCommand;
    defer command.deinit(allocator);
    const source_command = switch (command) {
        .source_load => |source| source,
        else => return error.ExpectedSourceCommand,
    };
    page.repository_read_authority.epoch = source_command.read_epoch.next();

    var finished: app_load.DiffLoadFinished = .{
        .identity = source_command.identity,
        .read_epoch = source_command.read_epoch,
        .generation = source_command.generation,
        .result = .{ .failed_static = "must not publish" },
    };
    defer finished.deinit(allocator);
    const applied = try controller.applySourceFinished(allocator, &finished, false);

    try std.testing.expect(!applied.terminal_admitted);
    try std.testing.expectEqual(RedrawDisposition.skip, applied.redraw);
    try std.testing.expect(applied.auto_reload_failure == null);
    try std.testing.expect(applied.recovered_failure == null);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
    try std.testing.expectEqual(retained_text, controller.navigation.view().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expectEqual(authority.MemberFreshness.pending, page.activation.state.members().?.source);
}

test "superseded repository read status terminal drains without publication" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var initial = try git_status.StatusBundle.parseOwned(allocator, "M  retained.zig\x00");
    try page.git_status.replace("/repo", &initial);
    page.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = page.auto_reload.beginCycle().?;
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareStatusLoad(allocator, "/repo", .background, cycle_id);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedStatusCommand;
    defer command.deinit(allocator);
    const status_command = switch (command) {
        .status_load => |status| status,
        else => return error.ExpectedStatusCommand,
    };
    controller.acceptStatusSpawn(cycle_id);
    page.auto_reload.supersedeActiveCycleByMutation();

    var finished: app_load.StatusLoadFinished = .{
        .identity = status_command.identity,
        .read_epoch = status_command.read_epoch,
        .generation = status_command.generation,
        .background_cycle_id = cycle_id,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "must not publish" },
    };
    defer finished.deinit(allocator);
    const applied = try controller.applyStatusFinished(allocator, &finished, false);

    try std.testing.expect(!applied.terminal_admitted);
    try std.testing.expect(applied.skip_redraw);
    try std.testing.expect(applied.diagnostic == null);
    try std.testing.expect(page.status_load.pending == null);
    try std.testing.expectEqual(auto_reload.AuxiliaryFreshness.stale_refresh, page.status_load.freshness);
    try std.testing.expectEqual(authority.MemberFreshness.pending, page.activation.state.members().?.status);
    try std.testing.expectEqual(@as(usize, 1), page.git_status.document.entries.len);
    try std.testing.expect(page.auto_reload.background_cycle == null);
}

test "old repository read branch terminal retires ownership without publication" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{};
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareBranchStatusLoad(allocator, "/repo", null);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedBranchCommand;
    defer command.deinit(allocator);
    const branch_command = switch (command) {
        .branch_status_load => |branch| branch,
        else => return error.ExpectedBranchCommand,
    };
    page.repository_read_authority.epoch = branch_command.read_epoch.next();

    var finished: app_load.BranchStatusLoadFinished = .{
        .identity = branch_command.identity,
        .read_epoch = branch_command.read_epoch,
        .generation = branch_command.generation,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "must not publish" },
    };
    defer finished.deinit(allocator);
    const applied = controller.applyBranchStatusFinished(&finished, false);

    try std.testing.expect(!applied.terminal_admitted);
    try std.testing.expect(applied.skip_redraw);
    try std.testing.expect(applied.diagnostic == null);
    try std.testing.expect(page.branch_status_load.pending == null);
    try std.testing.expectEqual(auto_reload.AuxiliaryFreshness.missing, page.branch_status_load.freshness);
    try std.testing.expectEqual(authority.MemberFreshness.pending, page.activation.state.members().?.branch);
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

test "projection read epoch is captured by page pending and task command" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    page.repository_read_authority.epoch = .{ .value = 41 };
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer command.deinit(allocator);

    try std.testing.expect(command.review_projection.read_epoch.eql(.{ .value = 41 }));
    try std.testing.expect(page.review_projection.pending.?.read_epoch.eql(.{ .value = 41 }));
    try std.testing.expect(command.review_projection.sameSemanticKey(page.review_projection.pending.?));
}

test "repository read projection terminals require current open epoch and exact pending owner" {
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

    // An exact terminal from a superseded epoch retires its page clone, but
    // cannot publish the task payload or schedule an eager presentation retry.
    {
        var update = try controller.prepareProjection(allocator);
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
        const request = switch (command) {
            .review_projection => |request| request,
            else => return error.ExpectedProjectionCommand,
        };
        command = undefined;
        page.repository_read_authority.epoch = request.read_epoch.next();

        var finished: app_load.ReviewProjectionFinished = .{
            .request = request,
            .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(
                allocator,
                "a",
                "must not publish\n",
            ) } },
        };
        defer finished.deinit(allocator);
        const applied = try controller.applyProjectionFinished(allocator, &finished);

        try std.testing.expect(!applied.result_transferred);
        try std.testing.expect(applied.skip_redraw);
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(!page.review_projection.hasDisplayed());
        try std.testing.expect(page.review_projection.eager_retry_basis == null);
    }

    // Equality of the scalar epoch is insufficient while the page-owned read
    // phase is closed by a mutation. Cleanup remains exact and infallible.
    {
        var update = try controller.prepareProjection(allocator);
        defer update.deinit(allocator);
        var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
        const request = switch (command) {
            .review_projection => |request| request,
            else => return error.ExpectedProjectionCommand,
        };
        command = undefined;
        page.repository_read_authority.phase = .{ .mutation_in_flight = .{
            .generation = 7,
            .kind = .stage_hunk,
        } };

        var finished: app_load.ReviewProjectionFinished = .{
            .request = request,
            .result = .{ .failed_static = "must not publish" },
        };
        defer finished.deinit(allocator);
        const applied = try controller.applyProjectionFinished(allocator, &finished);

        try std.testing.expect(!applied.result_transferred);
        try std.testing.expect(applied.skip_redraw);
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(!page.review_projection.hasDisplayed());
    }

    // A wrong/duplicate terminal never consumes the page clone belonging to
    // the current request.
    page.repository_read_authority.phase = .open;
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer command.deinit(allocator);
    const pending = page.review_projection.pending.?;
    var wrong: app_load.ReviewProjectionFinished = .{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            pending.identity,
            pending.id + 1,
            pending.repo_root,
            pending.path_key,
            pending.kind,
            pending.source_kind,
            pending.source_session_revision,
            pending.status_snapshot_revision,
            .{
                .read_epoch = pending.read_epoch,
                .root_identity = pending.root_identity,
                .expected_presentation = pending.expected_presentation,
            },
        ),
        .result = .{ .failed_static = "duplicate" },
    };
    defer wrong.deinit(allocator);
    const wrong_apply = try controller.applyProjectionFinished(allocator, &wrong);
    try std.testing.expect(wrong_apply.skip_redraw);
    try std.testing.expectEqual(pending.id, page.review_projection.pending.?.id);
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
    page.status_load.begin(null, .{});
    controller.rejectStatusSpawn(null);
    try std.testing.expect(page.status_load.pending == null);

    _ = page.branch_status_load.prepare(false);
    page.branch_status_load.begin(null, .{});
    controller.rejectBranchStatusSpawn(null);
    try std.testing.expect(page.branch_status_load.pending == null);

    page.review_projection.pending = try review_projection.testing.cloneRequest(
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
    _ = controller.rejectSourceSpawn(allocator, 11);
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
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "a", .generated_added_file, .unstaged, 0, 0));
    _ = try finishGeneratedProjection(controller, allocator, &second, "b");

    page.viewer.selected_target = .{ .status_only = 0 };
    page.review_projection.pending = try review_projection.testing.cloneRequest(
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
        .request = try review_projection.testing.cloneRequest(
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
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "b", .generated_added_file, .unstaged, 0, 0));

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
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "c", .generated_added_file, .unstaged, 0, 0));

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
        page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
    }
    try std.testing.expectEqual(review_projection.max_cached_entries, page.review_projection.cacheLen());

    page.review_projection.installReady(try testGeneratedReady(allocator, 5, "e", 0, 0));
    page.review_projection.pending = try review_projection.testing.cloneRequest(
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

    // captureAnchor separately owns the sticky path and sidebar identity, so
    // it performs the two permitted allocations. If old-display
    // admission unexpectedly needs cache metadata after removing the hit, the
    // next allocation fails; the hit must still remain installable either way.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    var update = try controller.prepareProjection(failing.allocator());
    defer update.deinit(allocator);

    try std.testing.expect(update.command == null);
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expectEqual(a_lines, page.review_projection.displayed.ready.value.generated_added_file.source.bytes.ptr);
    try std.testing.expectEqual(review_projection.max_cached_entries, page.review_projection.cacheLen());
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "e", .generated_added_file, .unstaged, 0, 0));
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
    page.repository_read_authority.epoch = .{ .value = 47 };
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    var controller = testController(&page, &status_message, .unstaged);
    controller.root_identity = root;

    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            page.activation.currentIdentity().?,
            11,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{
                .read_epoch = page.repository_read_authority.epoch,
                .root_identity = root,
            },
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(allocator, "a", "const value = 1;\n") },
    });

    var task_request = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRequest;
    defer task_request.deinit(allocator);
    try std.testing.expect(page.review_projection.hasSyntaxPending());
    try std.testing.expect(task_request.read_epoch.eql(.{ .value = 47 }));
    try std.testing.expect(page.review_projection.syntax_pending.?.read_epoch.eql(.{ .value = 47 }));
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
    const applied = controller.applyGeneratedSyntaxFinished(allocator, &finished);
    try std.testing.expect(!applied.skip_redraw);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
    const decorated_bundle = &page.review_projection.displayed.ready.value.generated_added_file;
    try std.testing.expect(decorated_bundle.decoration == .decorated);
    try std.testing.expect(decorated_bundle.decoration.hasVisibleSyntax());
    try std.testing.expect((try controller.prepareGeneratedSyntax(allocator)) == null);

    page.review_projection.cacheOrClearDisplayed(allocator, .{ .value = 47 }, "/repo", .unstaged, 0, 0);
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
        .request = try review_projection.testing.cloneRequestWithRootIdentity(
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
    page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
    try std.testing.expect(!page.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    var late = review_projection.GeneratedSyntaxFinished{
        .request = try review_projection.cloneGeneratedSyntaxRequest(allocator, task_request),
        .snapshot_fingerprint = task_request.expected_fingerprint,
        .result = .{ .loaded = .empty() },
    };
    defer late.deinit(allocator);
    const late_apply = controller.applyGeneratedSyntaxFinished(allocator, &late);
    try std.testing.expect(late_apply.skip_redraw);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    var promoted = try controller.prepareProjection(allocator);
    defer promoted.deinit(allocator);
    try std.testing.expect(promoted.command == null);
    try std.testing.expect(page.review_projection.displayed.ready.value.generated_added_file.decoration == .eligible);
    var retried = (try controller.prepareGeneratedSyntax(allocator)) orelse return error.ExpectedSyntaxRetry;
    defer retried.deinit(allocator);
}

test "old repository read generated syntax terminal drains without decorating retained projection" {
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 19, .inode = 23 };
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(allocator);
    page.repository_read_authority.epoch = .{ .value = 31 };
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    var status_message = @import("../../state.zig").StatusMessage{};
    var controller = testController(&page, &status_message, .unstaged);
    controller.root_identity = root;

    page.review_projection.installReady(.{
        .request = try review_projection.cloneRequestWithOptions(
            allocator,
            page.activation.currentIdentity().?,
            11,
            "/repo",
            "a",
            .generated_added_file,
            .unstaged,
            0,
            0,
            .{
                .read_epoch = page.repository_read_authority.epoch,
                .root_identity = root,
            },
        ),
        .value = .{ .generated_added_file = try review_projection.generatedFileFromContent(
            allocator,
            "a",
            "const retained = true;\n",
        ) },
    });
    const bundle = &page.review_projection.displayed.ready.value.generated_added_file;
    // Model an in-flight optional provider even in provider-none test builds.
    bundle.decoration = .eligible;
    page.review_projection.syntax_pending = try review_projection.generatedSyntaxRequestForProjection(
        allocator,
        17,
        page.activation.currentIdentity().?,
        page.review_projection.displayed.ready.request,
        bundle.fingerprint(),
    );
    var finished: review_projection.GeneratedSyntaxFinished = .{
        .request = try review_projection.cloneGeneratedSyntaxRequest(
            allocator,
            page.review_projection.syntax_pending.?,
        ),
        .snapshot_fingerprint = bundle.fingerprint(),
        .result = .{ .terminal_plain = .provider_unavailable },
    };
    defer finished.deinit(allocator);
    page.repository_read_authority.epoch = finished.request.read_epoch.next();

    const applied = controller.applyGeneratedSyntaxFinished(allocator, &finished);

    try std.testing.expect(applied.skip_redraw);
    try std.testing.expect(page.review_projection.syntax_pending == null);
    try std.testing.expect(bundle.decoration == .eligible);
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
    page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    _ = page.status_load.prepare(false);
    page.status_load.begin(null, .{});
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
    page.status_load.begin(null, .{});
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
    page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), page.review_projection.cacheLen());

    try controller.createStatusOnlyLoadedSession(allocator, status_bundle.document);
    try std.testing.expectEqual(@as(u64, 1), page.source_session_revision);
    try std.testing.expectEqual(@as(usize, 0), page.review_projection.cacheLen());
    try std.testing.expect(!page.review_projection.cacheHas(.{}, "/repo", "a", .generated_added_file, .unstaged, 0, 0));
}

fn testPageWithOwnedFileSearchCandidate(allocator: std.mem.Allocator) !review_page.ReviewPageState {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var arena_transferred = false;
    errdefer if (!arena_transferred) arena.deinit();
    const arena_allocator = arena.allocator();
    const path = try arena_allocator.dupe(u8, "src/owned.zig");
    const nodes = try arena_allocator.alloc(file_tree.Node, 1);
    nodes[0] = .{
        .kind = .file,
        .name = path[4..],
        .path = path,
        .path_key = path,
        .depth = 1,
        .status = .modified,
        .target = .{ .status_entry = 0 },
    };
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = nodes },
        .bytes = 0,
        .lines = 0,
    };

    var page: review_page.ReviewPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
    };
    arena_transferred = true;
    errdefer page.deinit(allocator);
    const basis: file_search.Basis = .{
        .repo_epoch = 0,
        .source_session_revision = page.source_session_revision,
        .accepted_sidebar_revision = page.accepted_sidebar_revision,
    };
    const active_loaded = switch (page.load.state) {
        .loaded => |*session| &session.loaded,
        else => unreachable,
    };
    var projection = try file_search.buildProjection(
        allocator,
        active_loaded,
        "owned",
        .{ .basis = basis },
    );
    page.file_search.mode = true;
    try page.file_search.input.insertSlice("owned");
    page.file_search.publish(allocator, &projection);
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expectEqualStrings("src/owned.zig", page.file_search.focusedCandidate().?.path_key);
    return page;
}

fn testPageWithDiffAndStatusOnlyFileSearchCandidate(allocator: std.mem.Allocator) !review_page.ReviewPageState {
    const text =
        \\diff --git a/src/current.zig b/src/current.zig
        \\--- a/src/current.zig
        \\+++ b/src/current.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\
    ;
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? src/legacy.zig\x00");
    errdefer status_bundle.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var arena_transferred = false;
    errdefer if (!arena_transferred) arena.deinit();
    const arena_allocator = arena.allocator();
    const document = try diff_parser.parse(arena_allocator, text);
    const eligibility = try arena_allocator.alloc(loaded_diff.FileTextEligibility, document.files.len);
    @memset(eligibility, .selectable_utf8);
    var loaded: loaded_diff.LoadedDiff = .{
        .text = text,
        .document = document,
        .file_text_eligibility = eligibility,
        .tree = try file_tree.buildWithOptions(arena_allocator, document, status_bundle.document, .{
            .root = .{ .name = "repo" },
        }),
        .bytes = text.len,
        .lines = std.mem.count(u8, text, "\n"),
    };
    try loaded.rebuildVisibleNodes(arena_allocator, .expanded, false, .all);

    var page: review_page.ReviewPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
    };
    arena_transferred = true;
    errdefer page.deinit(allocator);
    try page.git_status.replace("/repo", &status_bundle);
    const basis: file_search.Basis = .{
        .repo_epoch = 0,
        .source_session_revision = page.source_session_revision,
        .accepted_sidebar_revision = page.accepted_sidebar_revision,
    };
    const active_loaded = switch (page.load.state) {
        .loaded => |*session| &session.loaded,
        else => unreachable,
    };
    var projection = try file_search.buildProjection(allocator, active_loaded, "legacy", .{ .basis = basis });
    page.file_search.mode = true;
    try page.file_search.input.insertSlice("legacy");
    page.file_search.publish(allocator, &projection);
    try std.testing.expectEqual(file_search.TargetKind.status_only, page.file_search.focusedCandidate().?.target_kind);
    return page;
}

fn acceptEmptyStatus(
    allocator: std.mem.Allocator,
    controller: Controller,
    page: *review_page.ReviewPageState,
) !CompletionApply {
    _ = page.status_load.prepare(false);
    page.status_load.begin(null, .{});
    var finished: app_load.StatusLoadFinished = .{
        .identity = page.activation.currentIdentity().?,
        .generation = page.status_load.generation,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .empty,
    };
    defer finished.deinit(allocator);
    return controller.applyStatusFinished(allocator, &finished, false);
}

test "source replacement clears file search borrows before advancing its sidebar namespace" {
    const allocator = std.testing.allocator;
    var page = try testPageWithOwnedFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    controller.clearLoadedDiff(allocator);

    try std.testing.expectEqual(@as(u64, 1), page.source_session_revision);
    try std.testing.expectEqual(@as(u64, 2), page.accepted_sidebar_revision);
    try std.testing.expect(page.file_search.mode);
    try std.testing.expectEqualStrings("owned", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
}

test "source failure prepares its message then clears file search before freeing the load owner" {
    const allocator = std.testing.allocator;
    var page = try testPageWithOwnedFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, controller.replaceSourceFailure(failing.allocator(), "load failed"));
    try std.testing.expect(page.load.state == .loaded);
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expectEqual(@as(u64, 0), page.source_session_revision);
    try std.testing.expectEqual(@as(u64, 1), page.accepted_sidebar_revision);

    try controller.replaceSourceFailure(allocator, "load failed");

    try std.testing.expect(page.load.state == .failed);
    switch (page.load.state) {
        .failed => |failed| try std.testing.expectEqualStrings("load failed", failed.message),
        else => unreachable,
    }
    try std.testing.expectEqual(@as(u64, 1), page.source_session_revision);
    try std.testing.expectEqual(@as(u64, 2), page.accepted_sidebar_revision);
    try std.testing.expect(page.file_search.mode);
    try std.testing.expectEqualStrings("owned", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
}

test "accepted status replacement clears then republishes the retained file search query" {
    const allocator = std.testing.allocator;
    var page = try testPageWithOwnedFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    _ = page.status_load.prepare(false);
    page.status_load.begin(null, .{});
    var incoming = try git_status.StatusBundle.parseOwned(allocator, "?? src/owned.zig\x00");
    var finished: app_load.StatusLoadFinished = .{
        .identity = page.activation.currentIdentity().?,
        .generation = page.status_load.generation,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = incoming },
    };
    incoming = undefined;
    defer finished.deinit(allocator);

    const applied = try controller.applyStatusFinished(allocator, &finished, false);
    try std.testing.expect(applied.project_status != null);
    try std.testing.expectEqual(@as(u64, 2), page.accepted_sidebar_revision);
    try std.testing.expect(page.file_search.mode);
    try std.testing.expectEqualStrings("owned", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);

    try controller.applyStatusProjection(allocator, applied.project_status.?, .accepted_status);

    try std.testing.expect(page.file_search.projection_available);
    const candidate = page.file_search.focusedCandidate() orelse return error.ExpectedFileSearchCandidate;
    try std.testing.expectEqual(file_search.TargetKind.status_only, candidate.target_kind);
    try std.testing.expectEqualStrings("src/owned.zig", candidate.path_key);
    try std.testing.expectEqual(@as(u64, 2), candidate.basis.accepted_sidebar_revision);
    try std.testing.expectEqual(page.source_session_revision, candidate.basis.source_session_revision);
}

test "file search rebuild failure keeps prompt and publishes no stale candidate" {
    const allocator = std.testing.allocator;
    var page = try testPageWithOwnedFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.advanceAcceptedSidebarRevision(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    controller.navigation.rebuildFileSearchProjection(failing.allocator());

    try std.testing.expect(page.file_search.mode);
    try std.testing.expectEqualStrings("owned", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
}

test "empty status rebuild removes old status-only candidate before new basis publication" {
    const allocator = std.testing.allocator;
    var page = try testPageWithDiffAndStatusOnlyFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const applied = try acceptEmptyStatus(allocator, controller, &page);
    try std.testing.expect(applied.project_status != null);
    try std.testing.expectEqual(@as(u64, 2), page.accepted_sidebar_revision);
    try std.testing.expect(!page.file_search.projection_available);

    try controller.applyStatusProjection(allocator, applied.project_status.?, .accepted_status);

    const loaded = controller.navigation.activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    var found_current = false;
    for (loaded.tree.nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.path_key, "src/legacy.zig"));
        found_current = found_current or std.mem.eql(u8, node.path_key, "src/current.zig");
    }
    try std.testing.expect(found_current);
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expect(page.file_search.no_match);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
    try std.testing.expectEqual(@as(u64, 2), page.file_search.basis.?.accepted_sidebar_revision);
}

test "empty status action refresh keeps retained tree candidate unavailable" {
    const allocator = std.testing.allocator;
    var page = try testPageWithDiffAndStatusOnlyFileSearchCandidate(allocator);
    defer page.deinit(allocator);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    var prepared = try review_page.action_cursor.Prepared.init(
        allocator,
        0,
        .{ .device = 1, .inode = 2 },
        .file,
        "src/legacy.zig",
        0,
    );
    page.action_cursor.install(allocator, &prepared, 7);

    const applied = try acceptEmptyStatus(allocator, controller, &page);
    try std.testing.expect(applied.project_status != null);
    try controller.applyStatusProjection(allocator, applied.project_status.?, .accepted_status);

    const loaded = controller.navigation.activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    var retained_legacy = false;
    for (loaded.tree.nodes) |node| {
        retained_legacy = retained_legacy or std.mem.eql(u8, node.path_key, "src/legacy.zig");
    }
    try std.testing.expect(retained_legacy);
    try std.testing.expect(page.file_search.mode);
    try std.testing.expectEqualStrings("legacy", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
    try std.testing.expect(page.file_search.basis == null);
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
    page.review_projection.pending = try review_projection.testing.cloneRequest(
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
        .request = try review_projection.testing.cloneRequest(
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
    var request = try review_projection.testing.cloneRequest(
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
        .request = try review_projection.testing.cloneRequest(
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
    var cached_authority = try projection_component.ParsedComponent.parse(allocator, test_support.diff_cached_projection);
    var cached_authority_owned = true;
    defer if (cached_authority_owned) cached_authority.deinit();
    var unstaged_authority = try projection_component.ParsedComponent.parse(allocator, test_support.diff_unstaged_projection);
    var unstaged_authority_owned = true;
    defer if (unstaged_authority_owned) unstaged_authority.deinit();
    var presentation_arena = std.heap.ArenaAllocator.init(allocator);
    var presentation_owned = true;
    defer if (presentation_owned) presentation_arena.deinit();
    var authority_arena = std.heap.ArenaAllocator.init(allocator);
    var authority_owned = true;
    defer if (authority_owned) authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
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
            .presentation = .{
                .arena = presentation_arena,
                .projection = projection.presentation,
                .cached_bundle = cached_bundle,
                .unstaged_bundle = unstaged_bundle,
                .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
                .content_token = .init(combined_request.id),
            },
            .authority = .{
                .arena = authority_arena,
                .projection = projection.authority,
                .cached_component = cached_authority,
                .unstaged_component = unstaged_authority,
                .status_snapshot_revision = 0,
            },
        } } },
    };
    const combined_apply = try combined_controller.applyProjectionFinished(allocator, &combined_finished);
    try std.testing.expect(combined_apply.result_transferred);
    presentation_owned = false;
    authority_owned = false;
    cached_owned = false;
    unstaged_owned = false;
    cached_authority_owned = false;
    unstaged_authority_owned = false;
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

        page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
        try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "a", .combined_hunks, .unstaged, 0, 0));
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
    page.review_projection.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 0, 0);
    page.selection_owner = .{ .diff = .init(
        .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    var blocked_promotion = try controller.prepareProjection(allocator);
    defer blocked_promotion.deinit(allocator);
    try std.testing.expect(blocked_promotion.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "a", .generated_added_file, .unstaged, 0, 0));

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
    try std.testing.expect(page.review_projection.cacheHas(.{}, "/repo", "a", .generated_added_file, .unstaged, 0, 0));
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

test "mutation read promotion gate drains deferred projection without publication" {
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
        .result = .{ .ready = .{ .generated_added_file = try review_projection.generatedFileFromContent(
            allocator,
            "a",
            "must not publish\n",
        ) } },
    };
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const old_epoch = request.read_epoch;
    const deferred = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(deferred.result_transferred);
    finished_owned = false;
    try std.testing.expect(deferred.skip_redraw);
    try std.testing.expect(page.deferred_projection_apply != null);
    try std.testing.expect(page.review_projection.pending != null);

    const owner: app_actions.PendingAction = .{
        .generation = 55,
        .kind = .stage_hunk,
    };
    try std.testing.expect(page.repository_read_authority.closeForMutation(owner));
    try std.testing.expect(page.repository_read_authority.epoch.eql(old_epoch.next()));
    page.selection_owner = .none;
    try controller.applyDeferredProjection(allocator);

    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
}

test "combined content token survives exact index partition and rejects changed presentation" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    page.review_projection.installReady(.{
        .request = try review_projection.testing.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .combined_hunks,
            .unstaged,
            0,
            0,
        ),
        .value = .{ .combined_hunks = try testCombinedBundle(
            allocator,
            1,
            0,
            test_combined_before_cached,
            test_combined_before_unstaged,
        ) },
    });
    const original = &page.review_projection.displayed.ready.value.combined_hunks;
    const original_token = original.presentation.content_token;
    const original_cached_authority = original.authority.cached_component.fingerprint;
    page.completed_selection = try testCombinedCandidate(controller, allocator, original);
    const original_content = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", original_content, &.{ 0, 2 });
    try addTestSessionHunkMarks(&page, allocator, "/repo", "other.zig", original_content, &.{0});
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);

    var repartitioned = try testCombinedBundle(
        allocator,
        2,
        1,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    try std.testing.expect(original.presentation.fingerprint.eql(repartitioned.presentation.fingerprint));
    try std.testing.expect(diff_presentation_identity.exactEqual(original.displayFile(), repartitioned.displayFile()));
    controller.advanceStatusSnapshotRevision(allocator);
    try std.testing.expect(page.completed_selection != null);
    try applyTestCombinedBundle(controller, allocator, 2, 1, repartitioned);
    repartitioned = undefined;

    const accepted = &page.review_projection.displayed.ready.value.combined_hunks;
    try std.testing.expect(accepted.presentation.content_token.eql(original_token));
    try std.testing.expectEqual(@as(u64, 1), accepted.authority.status_snapshot_revision);
    try std.testing.expect(!accepted.authority.cached_component.fingerprint.eql(original_cached_authority));
    try std.testing.expect(accepted.authority.cached_component.fingerprint.eql(content_fingerprint.Fingerprint.init(test_combined_after_cached)));
    try std.testing.expect(page.completed_selection != null);
    try expectTestSessionHunkMarks(&page, "/repo", "a", original_content, &.{ 0, 2 });
    try std.testing.expectEqual(@import("../../../diff/selection.zig").Side.new, page.completed_selection.?.value.parsed_diff.side);
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);

    var changed = try testCombinedBundle(
        allocator,
        3,
        2,
        test_combined_after_cached,
        test_combined_changed_unstaged,
    );
    try std.testing.expect(!changed.presentation.fingerprint.eql(accepted.presentation.fingerprint));
    controller.advanceStatusSnapshotRevision(allocator);
    try std.testing.expect(page.completed_selection != null);
    try applyTestCombinedBundle(controller, allocator, 3, 2, changed);
    changed = undefined;
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(page.review_projection.displayed.ready.value.combined_hunks.presentation.content_token.eql(.init(3)));
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", .{
        .content = original_content,
        .display_hunk_index = 0,
    }));
    try expectTestSessionHunkMarks(&page, "/repo", "other.zig", original_content, &.{0});

    const changed_live = &page.review_projection.displayed.ready.value.combined_hunks;
    page.completed_selection = try testCombinedCandidate(controller, allocator, changed_live);
    const changed_content = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", changed_content, &.{ 0, 1 });
    var forced_digest_match = try testCombinedBundle(
        allocator,
        4,
        3,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    try std.testing.expect(!diff_presentation_identity.exactEqual(changed_live.displayFile(), forced_digest_match.displayFile()));
    forced_digest_match.presentation.fingerprint = changed_live.presentation.fingerprint;
    controller.advanceStatusSnapshotRevision(allocator);
    try std.testing.expect(page.completed_selection != null);
    try applyTestCombinedBundle(controller, allocator, 4, 3, forced_digest_match);
    forced_digest_match = undefined;
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", .{
        .content = changed_content,
        .display_hunk_index = 0,
    }));
    try expectTestSessionHunkMarks(&page, "/repo", "other.zig", original_content, &.{0});
    const forced_accepted = &page.review_projection.displayed.ready.value.combined_hunks;
    try std.testing.expect(forced_accepted.presentation.content_token.eql(.init(4)));
    try std.testing.expectEqual(@as(u64, 3), forced_accepted.authority.status_snapshot_revision);
}

test "combined replacement snapshots live presentation hint into page and task requests" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 41, 0);
    const live = &page.review_projection.displayed.ready.value.combined_hunks.presentation;
    const expected = review_projection.ExpectedPresentation{
        .fingerprint = live.fingerprint,
        .content_token = live.content_token,
    };
    controller.advanceStatusSnapshotRevision(allocator);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer command.deinit(allocator);
    const task_request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };

    const page_request = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(@as(u64, 1), page_request.status_snapshot_revision);
    try std.testing.expectEqual(@as(u64, 1), task_request.status_snapshot_revision);
    try std.testing.expect(page_request.expected_presentation.?.eql(expected));
    try std.testing.expect(task_request.expected_presentation.?.eql(expected));
    try std.testing.expect(page_request.expected_presentation.?.eql(task_request.expected_presentation.?));
}

test "combined reuse acceptance retains presentation and installs fresh authority" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 51, 0);
    const live_before = &page.review_projection.displayed.ready.value.combined_hunks;
    const presentation_text_ptr = live_before.presentation.cached_bundle.loaded.text.ptr;
    const presentation_syntax_ptr = live_before.presentation.cached_bundle.loaded.syntax_spans.files.ptr;
    const presentation_token = live_before.presentation.content_token;
    const old_authority_text_ptr = live_before.authority.cached_component.text.ptr;
    try std.testing.expect(live_before.authority.projection.hunk_action_origins[1] == .unstaged);
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);

    controller.advanceStatusSnapshotRevision(allocator);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        1,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    try std.testing.expect(candidate.fingerprint.eql(pending.expected_presentation.?.fingerprint));
    try std.testing.expect(diff_presentation_identity.exactEqual(live_before.displayFile(), candidate.displayFile()));
    try std.testing.expect(candidate.fresh_authority.?.cached_component.text.ptr != old_authority_text_ptr);
    try std.testing.expect(candidate.fresh_authority.?.projection.hunk_action_origins[1] == .cached);

    var finished: app_load.ReviewProjectionFinished = .{
        .request = try cloneTestProjectionRequest(allocator, pending),
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;

    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.eager_retry_basis == null);
    const accepted = &page.review_projection.displayed.ready;
    try std.testing.expectEqual(@as(u64, 1), accepted.request.status_snapshot_revision);
    const bundle = &accepted.value.combined_hunks;
    try std.testing.expect(bundle.presentation.cached_bundle.loaded.text.ptr == presentation_text_ptr);
    try std.testing.expect(bundle.presentation.cached_bundle.loaded.syntax_spans.files.ptr == presentation_syntax_ptr);
    try std.testing.expect(bundle.presentation.content_token.eql(presentation_token));
    try std.testing.expectEqual(@as(u64, 1), bundle.authority.status_snapshot_revision);
    try std.testing.expect(bundle.authority.cached_component.fingerprint.eql(content_fingerprint.Fingerprint.init(test_combined_after_cached)));
    try std.testing.expect(bundle.authority.projection.hunk_action_origins[1] == .cached);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, bundle.authority.projection.hunk_stage_states[1]);
    try std.testing.expect(page.completed_selection != null);
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "ordinary primary exact combined candidate retains primary presentation and installs authority" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary_before = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryDisplay,
    };
    const primary_owner = primary_before.loaded;
    const primary_text_ptr = primary_before.loaded.text.ptr;
    const primary_file = primary_before.loaded.document.files[primary_before.file_index];
    page.completed_selection = try testPrimaryCandidate(controller, allocator, primary_file);
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    const primary_token = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", primary_token, &.{ 0, 1 });

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    const expected = pending.expected_presentation orelse return error.ExpectedPrimaryPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.primary_loaded, expected.owner);
    try std.testing.expect(expected.fingerprint.eql(diff_presentation_identity.fingerprint(primary_file)));
    try std.testing.expect(expected.content_token.eql(.init(page.source_session_revision)));

    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    try std.testing.expect(request.expected_presentation.?.eql(expected));
    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    try std.testing.expect(candidate.fingerprint.eql(expected.fingerprint));
    try std.testing.expect(diff_presentation_identity.exactEqual(primary_file, candidate.displayFile()));

    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    const ready = &page.review_projection.displayed.ready;
    try std.testing.expect(ready.value == .primary_combined_authority);
    try std.testing.expect(!ready.value.cacheable());
    try std.testing.expectEqual(page.status_snapshot_revision, ready.value.primary_combined_authority.status_snapshot_revision);
    try std.testing.expect(controller.navigation.view().activeCombinedProjection() == null);
    const authority_view = controller.navigation.view().activeHunkAuthority() orelse return error.ExpectedCombinedAuthority;
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, authority_view.hunkStageStates()[0]);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, authority_view.hunkStageStates()[1]);
    try std.testing.expect(authority_view.hunkActionOrigins()[0] == .cached);
    try std.testing.expect(authority_view.hunkActionOrigins()[1] == .cached);
    try std.testing.expect(authority_view.hunkActionOrigins()[2] == .unstaged);

    const primary_after = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedRetainedPrimaryDisplay,
    };
    try std.testing.expect(primary_after.loaded == primary_owner);
    try std.testing.expect(primary_after.loaded.text.ptr == primary_text_ptr);
    try std.testing.expect(primary_after.hunk_authority != null);
    try std.testing.expect(primary_after.hunk_authority.? == .combined);
    try std.testing.expect(authority_view.authority == .combined);
    try std.testing.expect(primary_after.hunk_authority.?.combined == authority_view.authority.combined);

    const active = try controller.navigation.view().activeDiffDisplay(allocator, .unified) orelse return error.ExpectedActiveDisplay;
    defer switch (active.hunkStagePresentation()) {
        .per_hunk => |states| allocator.free(states),
        .all_staged, .all_unstaged => {},
    };
    try std.testing.expect(active == .loaded);
    try std.testing.expect(active.syntaxView() == .direct);
    try std.testing.expect(active.syntaxView().direct.document == &primary_owner.syntax_spans);
    try std.testing.expect(active.foldedHunks().ptr == primary_owner.foldedHunksForFile(0).ptr);
    try std.testing.expect(controller.navigation.view().displayedSearchTarget(.unified) != null);
    try std.testing.expect(active.hunkStagePresentation().stateForHunk(0) == .staged);
    try std.testing.expect(active.hunkStagePresentation().stateForHunk(1) == .staged);
    try std.testing.expect(active.hunkStagePresentation().stateForHunk(2) == .unstaged);

    try std.testing.expect(page.completed_selection != null);
    try expectTestSessionHunkMarks(&page, "/repo", "a", primary_token, &.{ 0, 1 });
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "ordinary primary staged-only status does not enter P5b boundary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryLoadState(allocator, test_support.diff_one),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } },
            .diff_scroll = 2,
            .diff_horizontal_scroll = 3,
        },
    };
    defer page.deinit(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary_before = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryDisplay,
    };
    const loaded_before = primary_before.loaded;
    const syntax_before = primary_before.loaded.syntax_spans.files.ptr;
    page.completed_selection = try testPrimaryCandidateAt(
        controller,
        allocator,
        primary_before.loaded.document.files[primary_before.file_index],
        2,
    );
    const mark_key: session_hunk_mark.Key = .{
        .content = controller.navigation.view().currentContentToken() orelse return error.ExpectedReviewContentToken,
        .display_hunk_index = 0,
    };
    try page.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    try page.search.query.insertSlice("new");
    controller.navigation.refreshSearchForSelectedFile();
    page.viewer.diff_scroll = 2;
    page.viewer.diff_horizontal_scroll = 3;
    const search_before = page.search.match.?;
    const search_offset_before = page.search.match_offset;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    try std.testing.expect(controller.view().projectionTarget() == null);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.displayed == .idle);

    const primary_after = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedRetainedPrimaryDisplay,
    };
    try std.testing.expect(primary_after.loaded == loaded_before);
    try std.testing.expect(primary_after.loaded.syntax_spans.files.ptr == syntax_before);
    try std.testing.expect(primary_after.hunk_authority == null);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expect(std.meta.eql(search_before, page.search.match.?));
    try std.testing.expectEqual(search_offset_before, page.search.match_offset);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
}

test "final hunk stage retains owned combined presentation with staged-only authority" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
            .diff_scroll = 5,
            .diff_horizontal_scroll = 4,
        },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 81, 0);
    const live = &page.review_projection.displayed.ready.value.combined_hunks;
    const presentation_text_ptr = live.presentation.cached_bundle.loaded.text.ptr;
    const presentation_syntax_ptr = live.presentation.cached_bundle.loaded.syntax_spans.files.ptr;
    const presentation_token = live.presentation.content_token;
    const combined_content = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", combined_content, &.{ 0, 2 });
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    try page.search.query.insertSlice("gamma");
    // Self-owned combined search is intentionally unsupported: retain the
    // non-empty query without silently starting its first match when the same
    // presentation crosses into staged-only.
    try std.testing.expect(page.search.match == null);
    page.viewer.diff_scroll = 5;
    page.viewer.diff_horizontal_scroll = 4;
    const search_before = page.search.match;
    const search_offset_before = page.search.match_offset;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    controller.advanceStatusSnapshotRevision(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.cached_diff, pending.kind);
    const expected = pending.expected_presentation orelse return error.ExpectedCombinedPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.combined_projection, expected.owner);

    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    var candidate = try testStagedOnlyReuseCandidate(allocator, page.status_snapshot_revision, test_combined_primary);
    try std.testing.expect(candidate.fingerprint.eql(expected.fingerprint));
    try std.testing.expect(diff_presentation_identity.exactEqual(live.displayFile(), candidate.displayFile()));
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    };
    candidate = undefined;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    const ready = &page.review_projection.displayed.ready;
    try std.testing.expectEqual(review_projection.Kind.cached_diff, ready.request.kind);
    try std.testing.expect(ready.value == .retained_staged_only);
    try std.testing.expect(ready.value.cacheable());
    const retained = &ready.value.retained_staged_only;
    try std.testing.expect(retained.presentation.cached_bundle.loaded.text.ptr == presentation_text_ptr);
    try std.testing.expect(retained.presentation.cached_bundle.loaded.syntax_spans.files.ptr == presentation_syntax_ptr);
    try std.testing.expect(retained.presentation.content_token.eql(presentation_token));
    try std.testing.expectEqual(page.status_snapshot_revision, retained.authority.status_snapshot_revision);
    for (retained.authority.projection.hunk_stage_states, retained.authority.projection.hunk_action_origins, 0..) |state, origin, hunk_index| {
        try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, state);
        try std.testing.expectEqual(hunk_index, origin.cached);
    }
    try std.testing.expect(std.meta.eql(search_before, page.search.match));
    try std.testing.expectEqual(search_offset_before, page.search.match_offset);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
    try std.testing.expectEqualStrings("a", controller.navigation.view().selectedStagePathKey().?);
    try std.testing.expect(controller.navigation.view().displayedSearchTarget(.unified) != null);
    const authority_view = controller.navigation.view().activeHunkAuthority() orelse return error.ExpectedStagedOnlyAuthority;
    try std.testing.expect(authority_view.authority == .staged_only);
    try std.testing.expect(page.completed_selection != null);
    try expectTestSessionHunkMarks(&page, "/repo", "a", combined_content, &.{ 0, 2 });
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "final hunk stage retains primary presentation with staged-only authority" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
            .diff_scroll = 6,
            .diff_horizontal_scroll = 2,
        },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary_before = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryDisplay,
    };
    const primary_owner = primary_before.loaded;
    const primary_text_ptr = primary_owner.text.ptr;
    const primary_syntax_ptr = primary_owner.syntax_spans.files.ptr;
    const primary_file = primary_owner.document.files[primary_before.file_index];
    page.completed_selection = try testPrimaryCandidate(controller, allocator, primary_file);

    var mixed_candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_before_cached,
        test_combined_before_unstaged,
    );
    const mixed_request = try review_projection.cloneRequestWithOptions(
        allocator,
        page.activation.currentIdentity().?,
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        page.source_session_revision,
        page.status_snapshot_revision,
        .{
            .read_epoch = .{},
            .expected_presentation = .{
                .owner = .primary_loaded,
                .fingerprint = mixed_candidate.fingerprint,
                .content_token = .init(page.source_session_revision),
            },
        },
    );
    page.review_projection.installReady(.{
        .request = mixed_request,
        .value = .{ .primary_combined_authority = mixed_candidate.discardCandidateAndTakeAuthority() },
    });
    mixed_candidate.deinit();
    try page.search.query.insertSlice("gamma");
    controller.navigation.refreshSearchForSelectedFile();
    controller.navigation.selectSearchMatch(.forward);
    page.viewer.diff_scroll = 6;
    page.viewer.diff_horizontal_scroll = 2;
    const search_before = page.search.match.?;
    const search_offset_before = page.search.match_offset;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    controller.advanceStatusSnapshotRevision(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    const boundary_body = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryBoundaryDisplay,
    };
    try std.testing.expect(boundary_body.hunk_authority != null);
    try std.testing.expect(boundary_body.hunk_authority.? == .combined);
    const boundary_target = controller.view().projectionTarget() orelse return error.ExpectedStagedOnlyTarget;
    try std.testing.expect(controller.expectedPresentationForTarget(boundary_target) != null);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.cached_diff, pending.kind);
    const expected = pending.expected_presentation orelse return error.ExpectedPrimaryPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.primary_loaded, expected.owner);

    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    var candidate = try testStagedOnlyReuseCandidate(allocator, page.status_snapshot_revision, test_combined_primary);
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    };
    candidate = undefined;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    const ready = &page.review_projection.displayed.ready;
    try std.testing.expect(ready.value == .primary_staged_only_authority);
    try std.testing.expect(!ready.value.cacheable());
    const primary_after = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedRetainedPrimaryDisplay,
    };
    try std.testing.expect(primary_after.loaded == primary_owner);
    try std.testing.expect(primary_after.loaded.text.ptr == primary_text_ptr);
    try std.testing.expect(primary_after.loaded.syntax_spans.files.ptr == primary_syntax_ptr);
    try std.testing.expect(primary_after.hunk_authority.? == .staged_only);
    const authority_view = controller.navigation.view().activeHunkAuthority() orelse return error.ExpectedStagedOnlyAuthority;
    try std.testing.expect(authority_view.authority == .staged_only);
    for (authority_view.hunkStageStates()) |state| try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, state);
    try std.testing.expect(std.meta.eql(search_before, page.search.match.?));
    try std.testing.expectEqual(search_offset_before, page.search.match_offset);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
    try std.testing.expect(controller.navigation.view().displayedSearchTarget(.unified) != null);
    try std.testing.expect(page.completed_selection != null);
}

test "one hunk unstage restores combined authority over retained owned presentation" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
            .diff_scroll = 5,
            .diff_horizontal_scroll = 4,
        },
    };
    defer page.deinit(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestRetainedStagedOnly(controller, allocator, 1, 101, page.status_snapshot_revision);
    const retained = &page.review_projection.displayed.ready.value.retained_staged_only;
    const presentation_text_ptr = retained.presentation.cached_bundle.loaded.text.ptr;
    const presentation_syntax_ptr = retained.presentation.cached_bundle.loaded.syntax_spans.files.ptr;
    const presentation_token = retained.presentation.content_token;
    const retained_content = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", retained_content, &.{ 0, 1 });
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    try page.search.query.insertSlice("gamma");
    // Self-owned combined search remains unsupported. P5c must not convert the
    // retained query into a new first match while authority changes underneath
    // the same rendered coordinates.
    try std.testing.expect(page.search.match == null);
    page.viewer.diff_scroll = 5;
    page.viewer.diff_horizontal_scroll = 4;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    controller.advanceStatusSnapshotRevision(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.combined_hunks, pending.kind);
    const expected = pending.expected_presentation orelse return error.ExpectedRetainedPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.combined_projection, expected.owner);
    try std.testing.expect(expected.content_token.eql(presentation_token));

    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    try std.testing.expect(candidate.fingerprint.eql(expected.fingerprint));
    try std.testing.expect(diff_presentation_identity.exactEqual(retained.displayFile(), candidate.displayFile()));
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    const ready = &page.review_projection.displayed.ready;
    try std.testing.expectEqual(review_projection.Kind.combined_hunks, ready.request.kind);
    try std.testing.expect(ready.value == .combined_hunks);
    const combined = &ready.value.combined_hunks;
    try std.testing.expect(combined.presentation.cached_bundle.loaded.text.ptr == presentation_text_ptr);
    try std.testing.expect(combined.presentation.cached_bundle.loaded.syntax_spans.files.ptr == presentation_syntax_ptr);
    try std.testing.expect(combined.presentation.content_token.eql(presentation_token));
    try std.testing.expectEqual(page.status_snapshot_revision, combined.authority.status_snapshot_revision);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, combined.authority.projection.hunk_stage_states[0]);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.staged, combined.authority.projection.hunk_stage_states[1]);
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.unstaged, combined.authority.projection.hunk_stage_states[2]);
    try std.testing.expect(combined.authority.projection.hunk_action_origins[0] == .cached);
    try std.testing.expect(combined.authority.projection.hunk_action_origins[2] == .unstaged);
    try std.testing.expect(page.search.match == null);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
    try std.testing.expect(page.completed_selection != null);
    try expectTestSessionHunkMarks(&page, "/repo", "a", retained_content, &.{ 0, 1 });
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "one hunk unstage restores combined authority over retained primary presentation" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
            .diff_scroll = 6,
            .diff_horizontal_scroll = 2,
        },
    };
    defer page.deinit(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestPrimaryStagedOnly(controller, allocator, 1, page.status_snapshot_revision);
    const primary_before = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryDisplay,
    };
    const primary_owner = primary_before.loaded;
    const primary_text_ptr = primary_owner.text.ptr;
    const primary_syntax_ptr = primary_owner.syntax_spans.files.ptr;
    page.completed_selection = try testPrimaryCandidate(
        controller,
        allocator,
        primary_owner.document.files[primary_before.file_index],
    );
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    try page.search.query.insertSlice("gamma");
    controller.navigation.refreshSearchForSelectedFile();
    controller.navigation.selectSearchMatch(.forward);
    page.viewer.diff_scroll = 6;
    page.viewer.diff_horizontal_scroll = 2;
    const search_before = page.search.match.?;
    const search_offset_before = page.search.match_offset;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    controller.advanceStatusSnapshotRevision(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.combined_hunks, pending.kind);
    const expected = pending.expected_presentation orelse return error.ExpectedPrimaryPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.primary_loaded, expected.owner);

    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);

    const ready = &page.review_projection.displayed.ready;
    try std.testing.expect(ready.value == .primary_combined_authority);
    try std.testing.expect(!ready.value.cacheable());
    const primary_after = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedRetainedPrimaryDisplay,
    };
    try std.testing.expect(primary_after.loaded == primary_owner);
    try std.testing.expect(primary_after.loaded.text.ptr == primary_text_ptr);
    try std.testing.expect(primary_after.loaded.syntax_spans.files.ptr == primary_syntax_ptr);
    try std.testing.expect(primary_after.hunk_authority.? == .combined);
    try std.testing.expect(std.meta.eql(search_before, page.search.match.?));
    try std.testing.expectEqual(search_offset_before, page.search.match_offset);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
    try std.testing.expect(page.completed_selection != null);
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "final staged hunk unstage returns owned combined display to exact ordinary primary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
            .diff_scroll = 5,
            .diff_horizontal_scroll = 3,
        },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary = controller.navigation.activeLoadedDiff().?;
    for (0..primary.document.files[0].hunks.len) |hunk_index| {
        primary.setHunkFolded(0, hunk_index, false);
    }
    const primary_text_ptr = primary.text.ptr;
    const primary_syntax_ptr = primary.syntax_spans.files.ptr;
    try installTestCombinedCandidate(controller, allocator, 1, 121, page.status_snapshot_revision);
    const combined_token = page.completed_selection.?.token;
    try addTestSessionHunkMarks(&page, allocator, "/repo", "a", combined_token, &.{ 0, 2 });
    try addTestSessionHunkMarks(&page, allocator, "/repo", "other.zig", combined_token, &.{0});
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    try page.search.query.insertSlice("gamma");
    _ = controller.navigation.view().selectedDiffCursorOffset() orelse
        return error.ExpectedCombinedCursorOffset;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    controller.advanceStatusSnapshotRevision(allocator);
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged_status);
    try std.testing.expect(controller.view().projectionTarget() == null);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    const ordinary = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |body| body,
        else => return error.ExpectedOrdinaryPrimaryDisplay,
    };
    try std.testing.expect(ordinary.loaded == primary);
    try std.testing.expect(ordinary.loaded.text.ptr == primary_text_ptr);
    try std.testing.expect(ordinary.loaded.syntax_spans.files.ptr == primary_syntax_ptr);
    try std.testing.expect(ordinary.hunk_authority == null);
    const ordinary_line_count = controller.navigation.view().displayedDiffLineCount();
    const cursor_offset_after = controller.navigation.view().selectedDiffCursorOffset() orelse
        return error.ExpectedRestoredPrimaryCursorOffset;
    try std.testing.expect(cursor_offset_after < ordinary_line_count);
    try std.testing.expect(page.viewer.diff_scroll < ordinary_line_count);
    try std.testing.expect(page.viewer.diff_horizontal_scroll <= horizontal_before);
    try std.testing.expect(page.search.match != null);
    try std.testing.expect(page.search.match_offset != null);
    try std.testing.expect(page.search.match_offset.? < ordinary_line_count);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(!page.completed_selection.?.token.eql(combined_token));
    try std.testing.expect(page.completed_selection.?.token.display == .loaded);
    try std.testing.expect(page.completed_selection.?.token.display.loaded.eql(.init(primary.text)));
    const ordinary_token = controller.navigation.view().currentContentToken() orelse
        return error.ExpectedReviewContentToken;
    try expectTestSessionHunkMarks(&page, "/repo", "a", ordinary_token, &.{ 0, 2 });
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", .{
        .content = combined_token,
        .display_hunk_index = 0,
    }));
    try expectTestSessionHunkMarks(&page, "/repo", "other.zig", combined_token, &.{0});
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "owned combined to folded primary remaps hidden cursor and clamps scroll" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 2, .line_index = 1 } },
        },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary = controller.navigation.activeLoadedDiff().?;
    primary.setHunkFolded(0, 2, true);
    try std.testing.expect(primary.isHunkFolded(0, 2));
    const folded_line_count = primary.renderedLineIndex(0, .unified).lineCount();

    try installTestCombinedCandidate(controller, allocator, 1, 122, page.status_snapshot_revision);
    const unfolded_line_count = controller.navigation.view().displayedDiffLineCount();
    try std.testing.expect(unfolded_line_count > folded_line_count);
    const unfolded_cursor_offset = controller.navigation.view().selectedDiffCursorOffset() orelse
        return error.ExpectedCombinedCursorOffset;
    page.viewer.diff_scroll = unfolded_line_count;

    controller.advanceStatusSnapshotRevision(allocator);
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(primary.isHunkFolded(0, 2));

    const ordinary_line_count = controller.navigation.view().displayedDiffLineCount();
    try std.testing.expectEqual(folded_line_count, ordinary_line_count);
    const ordinary_cursor_offset = controller.navigation.view().selectedDiffCursorOffset() orelse
        return error.ExpectedRestoredPrimaryCursorOffset;
    try std.testing.expectEqual(
        @min(unfolded_cursor_offset, ordinary_line_count - 1),
        ordinary_cursor_offset,
    );
    switch (page.viewer.diff_cursor) {
        .hunk_line => |line| try std.testing.expect(line.hunk_index != 2),
        else => {},
    }
    try std.testing.expect(page.viewer.diff_scroll < ordinary_line_count);
}

test "final staged hunk unstage removes primary combined authority without replacing primary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 1, .line_index = 1 } },
            .diff_scroll = 4,
            .diff_horizontal_scroll = 2,
        },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    const primary_before = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedPrimaryDisplay,
    };
    const primary_owner = primary_before.loaded;
    const primary_text_ptr = primary_owner.text.ptr;
    const primary_syntax_ptr = primary_owner.syntax_spans.files.ptr;
    page.completed_selection = try testPrimaryCandidate(
        controller,
        allocator,
        primary_owner.document.files[primary_before.file_index],
    );
    const loaded_token = page.completed_selection.?.token;
    const original_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(original_clipboard);
    try page.search.query.insertSlice("beta");
    controller.navigation.refreshSearchForSelectedFile();
    controller.navigation.selectSearchMatch(.forward);
    page.viewer.diff_scroll = 4;
    page.viewer.diff_horizontal_scroll = 2;
    const search_before = page.search.match.?;
    const search_offset_before = page.search.match_offset;
    const cursor_before = page.viewer.diff_cursor;
    const scroll_before = page.viewer.diff_scroll;
    const horizontal_before = page.viewer.diff_horizontal_scroll;

    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_before_cached,
        test_combined_before_unstaged,
    );
    defer candidate.deinit();
    page.review_projection.installReady(.{
        .request = try review_projection.testing.cloneRequest(
            allocator,
            page.activation.currentIdentity().?,
            1,
            "/repo",
            "a",
            .combined_hunks,
            .unstaged,
            page.source_session_revision,
            page.status_snapshot_revision,
        ),
        .value = .{ .primary_combined_authority = candidate.discardCandidateAndTakeAuthority() },
    });

    controller.advanceStatusSnapshotRevision(allocator);
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());

    const primary_after = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedOrdinaryPrimaryDisplay,
    };
    try std.testing.expect(primary_after.loaded == primary_owner);
    try std.testing.expect(primary_after.loaded.text.ptr == primary_text_ptr);
    try std.testing.expect(primary_after.loaded.syntax_spans.files.ptr == primary_syntax_ptr);
    try std.testing.expect(primary_after.hunk_authority == null);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(loaded_token));
    try std.testing.expect(std.meta.eql(search_before, page.search.match.?));
    try std.testing.expectEqual(search_offset_before, page.search.match_offset);
    try std.testing.expect(std.meta.eql(cursor_before, page.viewer.diff_cursor));
    try std.testing.expectEqual(scroll_before, page.viewer.diff_scroll);
    try std.testing.expectEqual(horizontal_before, page.viewer.diff_horizontal_scroll);
    const accepted_clipboard = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(accepted_clipboard);
    try std.testing.expectEqualStrings(original_clipboard, accepted_clipboard);
}

test "session-staged hunk projected unstage removes exact mark before next toggle" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_header = 0 },
        },
    };
    defer page.deinit(allocator);
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged_status);
    page.status_load.markSuccess();
    _ = page.activation.activate(0, .fresh, .fresh, .fresh);
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var operation_view: review_operations.View = .{
        .page = &page,
        .navigation = controller.navigation.view(),
        .source = .unstaged,
        .repo_root = "/repo",
        .activation_state = page.activation.state,
    };
    var operation_controller: review_operations.Controller = .{
        .page = &page,
        .navigation = controller.navigation,
        .view_state = operation_view,
    };

    const stage_target = switch (operation_view.selectedHunkStageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedReadyHunkStageTarget,
    };
    defer allocator.free(stage_target.patch);
    const mark_key = switch (stage_target.session_mark_mutation) {
        .add => |key| key,
        else => return error.ExpectedSessionHunkMarkAdd,
    };
    const stage_apply = operation_controller.applyAcceptedOutcome(allocator, .{ .stage_hunk = .{
        .repo_root = stage_target.repo_root,
        .path = stage_target.path,
        .hunk_index = stage_target.hunk_index,
        .session_mark_mutation = stage_target.session_mark_mutation,
    } }, true);
    try std.testing.expect(stage_apply.reload == .status);
    try std.testing.expect(page.staged_hunks.containsExact("/repo", "a", mark_key));

    controller.advanceStatusSnapshotRevision(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_before_cached,
        test_combined_before_unstaged,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    const projection_apply = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(projection_apply.result_transferred);
    try std.testing.expect(page.staged_hunks.containsExact("/repo", "a", mark_key));

    operation_view = .{
        .page = &page,
        .navigation = controller.navigation.view(),
        .source = .unstaged,
        .repo_root = "/repo",
        .activation_state = page.activation.state,
    };
    operation_controller = .{
        .page = &page,
        .navigation = controller.navigation,
        .view_state = operation_view,
    };
    const unstage_target = switch (operation_view.selectedHunkUnstageTarget(allocator)) {
        .ready => |target| target,
        else => return error.ExpectedReadyHunkUnstageTarget,
    };
    defer allocator.free(unstage_target.patch);
    try std.testing.expect(unstage_target.session_mark_mutation == .remove);
    try std.testing.expect(unstage_target.session_mark_mutation.remove.eql(mark_key));
    const unstage_apply = operation_controller.applyAcceptedOutcome(allocator, .{ .unstage_hunk = .{
        .repo_root = unstage_target.repo_root,
        .path = unstage_target.path,
        .hunk_index = unstage_target.hunk_index,
        .session_mark_mutation = unstage_target.session_mark_mutation,
        .reload_after_success = unstage_target.reload_after_success,
    } }, true);
    try std.testing.expect(unstage_apply.reload == .status);
    try std.testing.expect(!page.staged_hunks.containsExact("/repo", "a", mark_key));

    controller.advanceStatusSnapshotRevision(allocator);
    var final_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &final_status);
    var final_update = try controller.prepareProjection(allocator);
    defer final_update.deinit(allocator);
    try std.testing.expect(final_update.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());

    const final_view: review_operations.View = .{
        .page = &page,
        .navigation = controller.navigation.view(),
        .source = .unstaged,
        .repo_root = "/repo",
        .activation_state = page.activation.state,
    };
    try std.testing.expectEqual(
        @import("../../git_ops.zig").ToggleHunkTargetResult{ .operation = .stage },
        final_view.selectedHunkToggleOperation(),
    );
}

test "combined to ordinary mismatch clears projection selection before revealing primary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryLoadState(allocator, test_combined_primary_changed),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    try installTestCombinedCandidate(controller, allocator, 1, 131, page.status_snapshot_revision);
    try std.testing.expect(!diff_presentation_identity.exactEqual(
        page.review_projection.displayed.ready.value.combined_hunks.displayFile(),
        controller.navigation.view().selectedFile().?,
    ));

    controller.advanceStatusSnapshotRevision(allocator);
    var unstaged_status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00");
    try page.git_status.replace("/repo", &unstaged_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(!page.review_projection.hasDisplayed());
    try std.testing.expect(page.completed_selection == null);
    const ordinary = switch (controller.navigation.view().displayedReviewBody()) {
        .primary => |primary| primary,
        else => return error.ExpectedOrdinaryPrimaryDisplay,
    };
    try std.testing.expect(diff_presentation_identity.exactEqual(
        ordinary.loaded.document.files[ordinary.file_index],
        controller.navigation.view().selectedFile().?,
    ));
}

test "staged-only to combined exact mismatch keeps retained owner for bounded eager retry" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    try installTestRetainedStagedOnly(controller, allocator, 1, 111, page.status_snapshot_revision);

    controller.advanceStatusSnapshotRevision(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    const expected = pending.expected_presentation orelse return error.ExpectedRetainedPresentationHint;
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;

    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_after_cached,
        test_combined_changed_unstaged,
    );
    candidate.fingerprint = expected.fingerprint;
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    defer finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(!applied.result_transferred);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.displayed.ready.value == .retained_staged_only);
    try std.testing.expect(page.review_projection.eager_retry_basis.?.eql(expected));

    var retry = try controller.prepareProjection(allocator);
    defer retry.deinit(allocator);
    const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.combined_hunks, retry_pending.kind);
    try std.testing.expect(retry_pending.expected_presentation == null);
    var retry_command = retry.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer retry_command.deinit(allocator);
    switch (retry_command) {
        .review_projection => |retry_request| try std.testing.expect(retry_request.expected_presentation == null),
        else => return error.ExpectedProjectionCommand,
    }
}

test "staged-only exact mismatch schedules one eager cached boundary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &mixed_status);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);
    try installTestCombinedCandidate(controller, allocator, 1, 91, 0);

    controller.advanceStatusSnapshotRevision(allocator);
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
    try page.git_status.replace("/repo", &staged_status);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    const expected = pending.expected_presentation orelse return error.ExpectedCombinedPresentationHint;
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;

    var candidate = try testStagedOnlyReuseCandidate(allocator, page.status_snapshot_revision, test_combined_primary_changed);
    try std.testing.expect(!diff_presentation_identity.exactEqual(
        controller.navigation.view().activeCombinedProjection().?.displayFile(),
        candidate.displayFile(),
    ));
    candidate.fingerprint = expected.fingerprint;
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .staged_only_reuse_candidate = candidate },
    };
    candidate = undefined;
    defer finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(!applied.result_transferred);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.eager_retry_basis.?.eql(expected));
    try std.testing.expect(page.review_projection.displayed.ready.value == .combined_hunks);

    var retry = try controller.prepareProjection(allocator);
    defer retry.deinit(allocator);
    const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expectEqual(review_projection.Kind.cached_diff, retry_pending.kind);
    try std.testing.expect(retry_pending.expected_presentation == null);
    var retry_command = retry.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer retry_command.deinit(allocator);
    switch (retry_command) {
        .review_projection => |retry_request| try std.testing.expect(retry_request.expected_presentation == null),
        else => return error.ExpectedProjectionCommand,
    }
}

test "malformed staged-only candidate shape rejects before file access" {
    const MalformedShape = enum { zero_files, multiple_files };
    const allocator = std.testing.allocator;

    for ([_]MalformedShape{ .zero_files, .multiple_files }) |shape| {
        var page: review_page.ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        };
        defer page.deinit(allocator);
        var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
        try page.git_status.replace("/repo", &mixed_status);
        page.status_load.markSuccess();
        var status_message = @import("../../state.zig").StatusMessage{};
        const controller = testController(&page, &status_message, .unstaged);
        try installTestCombinedCandidate(controller, allocator, 1, 92, 0);

        controller.advanceStatusSnapshotRevision(allocator);
        var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00");
        try page.git_status.replace("/repo", &staged_status);
        var update = try controller.prepareProjection(allocator);
        defer update.deinit(allocator);
        const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        const expected = pending.expected_presentation orelse return error.ExpectedCombinedPresentationHint;
        var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
        const request = switch (command) {
            .review_projection => |request| request,
            else => return error.ExpectedProjectionCommand,
        };
        command = undefined;

        var candidate = try testStagedOnlyReuseCandidate(
            allocator,
            page.status_snapshot_revision,
            test_combined_primary,
        );
        const original_file = candidate.fresh_authority.?.cached_component.document.files[0];
        var duplicate_files = [_]diff_parser.FileDiff{ original_file, original_file };
        candidate.fresh_authority.?.cached_component.document.files = switch (shape) {
            .zero_files => &.{},
            .multiple_files => duplicate_files[0..],
        };
        var finished: app_load.ReviewProjectionFinished = .{
            .request = request,
            .result = .{ .staged_only_reuse_candidate = candidate },
        };
        candidate = undefined;
        defer finished.deinit(allocator);

        const applied = try controller.applyProjectionFinished(allocator, &finished);
        try std.testing.expect(!applied.result_transferred);
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(page.review_projection.eager_retry_basis.?.eql(expected));
        try std.testing.expect(page.review_projection.displayed.ready.value == .combined_hunks);
        try std.testing.expect(controller.navigation.view().activeHunkAuthority().?.authority == .combined);
        try std.testing.expect(finished.result.staged_only_reuse_candidate.fresh_authority != null);

        var retry = try controller.prepareProjection(allocator);
        defer retry.deinit(allocator);
        const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        try std.testing.expect(retry_pending.expected_presentation == null);
        var retry_command = retry.takeCommand() orelse return error.ExpectedProjectionCommand;
        defer retry_command.deinit(allocator);
        switch (retry_command) {
            .review_projection => |retry_request| try std.testing.expect(retry_request.expected_presentation == null),
            else => return error.ExpectedProjectionCommand,
        }
    }
}

test "ordinary primary combined candidate exact mismatch schedules one eager boundary" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = try testPrimaryCombinedLoadState(allocator),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    const expected = pending.expected_presentation orelse return error.ExpectedPrimaryPresentationHint;
    try std.testing.expectEqual(review_projection.ExpectedPresentationOwner.primary_loaded, expected.owner);
    var command = update.takeCommand() orelse return error.ExpectedProjectionCommand;
    const request = switch (command) {
        .review_projection => |request| request,
        else => return error.ExpectedProjectionCommand,
    };
    command = undefined;

    var candidate = try testCombinedReuseCandidate(
        allocator,
        page.status_snapshot_revision,
        test_combined_before_cached,
        test_combined_changed_unstaged,
    );
    try std.testing.expect(!diff_presentation_identity.exactEqual(
        controller.navigation.view().selectedFile().?,
        candidate.displayFile(),
    ));
    candidate.fingerprint = expected.fingerprint;
    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;
    defer finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(!applied.result_transferred);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.eager_retry_basis != null);
    try std.testing.expectEqual(
        review_projection.ExpectedPresentationOwner.primary_loaded,
        page.review_projection.eager_retry_basis.?.owner,
    );
    try std.testing.expect(controller.navigation.view().displayedReviewBody() == .primary);
    try std.testing.expect(controller.navigation.view().activeHunkAuthority() == null);

    var retry = try controller.prepareProjection(allocator);
    defer retry.deinit(allocator);
    const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expect(retry_pending.expected_presentation == null);
    var retry_command = retry.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer retry_command.deinit(allocator);
    switch (retry_command) {
        .review_projection => |retry_request| try std.testing.expect(retry_request.expected_presentation == null),
        else => return error.ExpectedProjectionCommand,
    }
}

const CombinedReuseRejection = enum {
    expected_token_changed,
    forced_fingerprint_collision,
    stale_authority_revision,
};

fn testCombinedReuseRejection(
    allocator: std.mem.Allocator,
    rejection: CombinedReuseRejection,
) !void {
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 61, 0);
    const live_before = &page.review_projection.displayed.ready.value.combined_hunks;
    const presentation_text_ptr = live_before.presentation.cached_bundle.loaded.text.ptr;
    const authority_text_ptr = live_before.authority.cached_component.text.ptr;
    const presentation_token = live_before.presentation.content_token;
    controller.advanceStatusSnapshotRevision(allocator);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;

    const candidate_unstaged = if (rejection == .forced_fingerprint_collision)
        test_combined_changed_unstaged
    else
        test_combined_after_unstaged;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        1,
        test_combined_after_cached,
        candidate_unstaged,
    );
    var request = try cloneTestProjectionRequest(allocator, pending);
    switch (rejection) {
        .expected_token_changed => request.expected_presentation.?.content_token = .init(999),
        .forced_fingerprint_collision => {
            try std.testing.expect(!diff_presentation_identity.exactEqual(live_before.displayFile(), candidate.displayFile()));
            candidate.fingerprint = request.expected_presentation.?.fingerprint;
        },
        .stale_authority_revision => candidate.fresh_authority.?.status_snapshot_revision = 0,
    }

    var finished: app_load.ReviewProjectionFinished = .{
        .request = request,
        .result = .{ .reuse_candidate = candidate },
    };
    request = undefined;
    candidate = undefined;
    defer finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(!applied.result_transferred);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.eager_retry_basis != null);

    const retained = &page.review_projection.displayed.ready.value.combined_hunks;
    try std.testing.expect(retained.presentation.cached_bundle.loaded.text.ptr == presentation_text_ptr);
    try std.testing.expect(retained.authority.cached_component.text.ptr == authority_text_ptr);
    try std.testing.expect(retained.presentation.content_token.eql(presentation_token));
    try std.testing.expectEqual(@as(u64, 0), retained.authority.status_snapshot_revision);
    try std.testing.expect(page.completed_selection != null);

    if (rejection == .forced_fingerprint_collision) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, controller.prepareProjection(failing.allocator()));
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(page.review_projection.eager_retry_basis != null);
    }

    var retry_update = try controller.prepareProjection(allocator);
    defer retry_update.deinit(allocator);
    const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expect(retry_pending.expected_presentation == null);
    var retry_command = retry_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer retry_command.deinit(allocator);
    const retry_request = switch (retry_command) {
        .review_projection => |owned_request| owned_request,
        else => return error.ExpectedProjectionCommand,
    };
    try std.testing.expect(retry_request.expected_presentation == null);
    try std.testing.expectEqual(retry_pending.id, retry_request.id);
    try std.testing.expect(page.review_projection.eager_retry_basis != null);

    if (rejection == .forced_fingerprint_collision) {
        const rejected_spawn_id = retry_pending.id;
        controller.rejectProjectionSpawn(allocator, rejected_spawn_id);
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(page.review_projection.eager_retry_basis != null);

        var respawn_update = try controller.prepareProjection(allocator);
        defer respawn_update.deinit(allocator);
        const respawn_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        try std.testing.expect(respawn_pending.expected_presentation == null);
        try std.testing.expect(respawn_pending.id != rejected_spawn_id);
        var respawn_command = respawn_update.takeCommand() orelse return error.ExpectedProjectionCommand;
        defer respawn_command.deinit(allocator);
        switch (respawn_command) {
            .review_projection => |owned_request| try std.testing.expect(owned_request.expected_presentation == null),
            else => return error.ExpectedProjectionCommand,
        }
    }
}

test "combined reuse rejection keeps old display inert and schedules one eager request" {
    const allocator = std.testing.allocator;
    try testCombinedReuseRejection(allocator, .expected_token_changed);
    try testCombinedReuseRejection(allocator, .forced_fingerprint_collision);
    try testCombinedReuseRejection(allocator, .stale_authority_revision);
}

test "combined reuse candidate crosses live drag deferral with one owner" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 71, 0);
    controller.advanceStatusSnapshotRevision(allocator);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        1,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = try cloneTestProjectionRequest(allocator, pending),
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;

    page.selection_owner = .{ .diff = .init(
        .{ .projection_file = .{ .kind = .combined, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    const deferred = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(deferred.result_transferred);
    try std.testing.expect(page.deferred_projection_apply != null);
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expectEqual(@as(u64, 0), page.review_projection.displayed.ready.value.combined_hunks.authority.status_snapshot_revision);

    page.selection_owner = .none;
    try controller.applyDeferredProjection(allocator);
    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expectEqual(@as(u64, 1), page.review_projection.displayed.ready.value.combined_hunks.authority.status_snapshot_revision);
}

test "deferred combined reuse rejection schedules the same bounded eager retry" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 72, 0);
    controller.advanceStatusSnapshotRevision(allocator);
    var initial_update = try controller.prepareProjection(allocator);
    defer initial_update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    var candidate = try testCombinedReuseCandidate(
        allocator,
        1,
        test_combined_after_cached,
        test_combined_changed_unstaged,
    );
    candidate.fingerprint = pending.expected_presentation.?.fingerprint;
    var finished: app_load.ReviewProjectionFinished = .{
        .request = try cloneTestProjectionRequest(allocator, pending),
        .result = .{ .reuse_candidate = candidate },
    };
    candidate = undefined;

    page.selection_owner = .{ .diff = .init(
        .{ .projection_file = .{ .kind = .combined, .path_key = "a" } },
        .new,
        .{ .hunk_index = 0, .line_index = 0 },
    ) };
    const deferred = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(deferred.result_transferred);
    try std.testing.expect(page.deferred_projection_apply != null);

    page.selection_owner = .none;
    try controller.applyDeferredProjection(allocator);
    try std.testing.expect(page.deferred_projection_apply == null);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.review_projection.eager_retry_basis != null);
    try std.testing.expectEqual(@as(u64, 0), page.review_projection.displayed.ready.value.combined_hunks.authority.status_snapshot_revision);

    var retry_update = try controller.prepareProjection(allocator);
    defer retry_update.deinit(allocator);
    const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expect(retry_pending.expected_presentation == null);
    var retry_command = retry_update.takeCommand() orelse return error.ExpectedProjectionCommand;
    defer retry_command.deinit(allocator);
    switch (retry_command) {
        .review_projection => |request| try std.testing.expect(request.expected_presentation == null),
        else => return error.ExpectedProjectionCommand,
    }
}

test "hint-free eager completion consumes retry budget and preserves exact presentation token" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 73, 0);
    const old_token = page.review_projection.displayed.ready.value.combined_hunks.presentation.content_token;
    controller.advanceStatusSnapshotRevision(allocator);
    page.review_projection.scheduleEagerRetry(.{
        .fingerprint = page.review_projection.displayed.ready.value.combined_hunks.presentation.fingerprint,
        .content_token = old_token,
    });
    var retry_update = try controller.prepareProjection(allocator);
    defer retry_update.deinit(allocator);
    const pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
    try std.testing.expect(pending.expected_presentation == null);

    var eager_bundle = try testCombinedBundle(
        allocator,
        pending.id,
        1,
        test_combined_after_cached,
        test_combined_after_unstaged,
    );
    var finished: app_load.ReviewProjectionFinished = .{
        .request = try cloneTestProjectionRequest(allocator, pending),
        .result = .{ .ready = .{ .combined_hunks = eager_bundle } },
    };
    eager_bundle = undefined;
    var finished_owned = true;
    defer if (finished_owned) finished.deinit(allocator);
    const applied = try controller.applyProjectionFinished(allocator, &finished);
    try std.testing.expect(applied.result_transferred);
    finished_owned = false;

    try std.testing.expect(page.review_projection.eager_retry_basis == null);
    try std.testing.expect(page.review_projection.pending == null);
    const accepted = &page.review_projection.displayed.ready.value.combined_hunks;
    try std.testing.expectEqual(@as(u64, 1), accepted.authority.status_snapshot_revision);
    try std.testing.expect(accepted.presentation.content_token.eql(old_token));
    try std.testing.expect(page.completed_selection != null);
}

test "combined hint-free eager completion anchor allocation failure closes pending and preserves retry" {
    const backing = std.testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var page: review_page.ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        };
        defer page.deinit(backing);
        var status_bundle = try git_status.StatusBundle.parseOwned(backing, "MM a\x00");
        try page.git_status.replace("/repo", &status_bundle);
        page.status_load.markSuccess();
        var status_message = @import("../../state.zig").StatusMessage{};
        const controller = testController(&page, &status_message, .unstaged);

        try installTestCombinedCandidate(controller, backing, 1, 74 + fail_index, 0);
        const retained_before = &page.review_projection.displayed.ready.value.combined_hunks;
        const presentation_text_ptr = retained_before.presentation.cached_bundle.loaded.text.ptr;
        const authority_text_ptr = retained_before.authority.cached_component.text.ptr;
        controller.advanceStatusSnapshotRevision(backing);

        var candidate_update = try controller.prepareProjection(backing);
        defer candidate_update.deinit(backing);
        const candidate_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        var candidate = try testCombinedReuseCandidate(
            backing,
            1,
            test_combined_after_cached,
            test_combined_changed_unstaged,
        );
        // Force the fingerprint gate to reach the exact comparison, which
        // rejects this changed presentation and schedules the eager fallback.
        candidate.fingerprint = candidate_pending.expected_presentation.?.fingerprint;
        var candidate_finished: app_load.ReviewProjectionFinished = .{
            .request = try cloneTestProjectionRequest(backing, candidate_pending),
            .result = .{ .reuse_candidate = candidate },
        };
        candidate = undefined;
        defer candidate_finished.deinit(backing);
        const rejected = try controller.applyProjectionFinished(backing, &candidate_finished);
        try std.testing.expect(!rejected.result_transferred);
        try std.testing.expect(page.review_projection.pending == null);
        const retry_basis = page.review_projection.eager_retry_basis orelse return error.ExpectedEagerRetry;

        var retry_update = try controller.prepareProjection(backing);
        defer retry_update.deinit(backing);
        const retry_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        const failed_request_id = retry_pending.id;
        try std.testing.expect(retry_pending.expected_presentation == null);
        const retry_task = retry_update.command orelse return error.ExpectedProjectionCommand;
        switch (retry_task) {
            .review_projection => |request| try std.testing.expect(request.expected_presentation == null),
            else => return error.ExpectedProjectionCommand,
        }

        var eager_bundle = try testCombinedBundle(
            backing,
            retry_pending.id,
            1,
            test_combined_after_cached,
            test_combined_after_unstaged,
        );
        var eager_finished: app_load.ReviewProjectionFinished = .{
            .request = try cloneTestProjectionRequest(backing, retry_pending),
            .result = .{ .ready = .{ .combined_hunks = eager_bundle } },
        };
        eager_bundle = undefined;
        defer eager_finished.deinit(backing);

        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        try std.testing.expectError(
            error.OutOfMemory,
            controller.applyProjectionFinished(failing.allocator(), &eager_finished),
        );

        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(page.review_projection.eager_retry_basis.?.eql(retry_basis));
        const retained_after = &page.review_projection.displayed.ready.value.combined_hunks;
        try std.testing.expect(retained_after.presentation.cached_bundle.loaded.text.ptr == presentation_text_ptr);
        try std.testing.expect(retained_after.authority.cached_component.text.ptr == authority_text_ptr);
        try std.testing.expectEqual(@as(u64, 0), retained_after.authority.status_snapshot_revision);
        try std.testing.expect(page.completed_selection != null);

        var replacement_update = try controller.prepareProjection(backing);
        defer replacement_update.deinit(backing);
        const replacement_pending = page.review_projection.pending orelse return error.ExpectedPendingProjection;
        try std.testing.expect(replacement_pending.id != failed_request_id);
        try std.testing.expect(replacement_pending.expected_presentation == null);
        var replacement_command = replacement_update.takeCommand() orelse return error.ExpectedProjectionCommand;
        defer replacement_command.deinit(backing);
        switch (replacement_command) {
            .review_projection => |request| try std.testing.expect(request.expected_presentation == null),
            else => return error.ExpectedProjectionCommand,
        }
    }
}

test "combined candidate closes when replacement request allocation fails" {
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
        page.status_load.markSuccess();
        var status_message = @import("../../state.zig").StatusMessage{};
        const controller = testController(&page, &status_message, .unstaged);

        try installTestCombinedCandidate(controller, backing, 1, 1, 0);
        controller.advanceStatusSnapshotRevision(backing);
        try std.testing.expect(page.completed_selection != null);

        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, controller.prepareProjection(failing.allocator()));
        try std.testing.expect(page.review_projection.pending == null);
        try std.testing.expect(page.completed_selection == null);
    }
}

test "combined candidate spawn rejection closes only the matching replacement" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try page.git_status.replace("/repo", &status_bundle);
    page.status_load.markSuccess();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    try installTestCombinedCandidate(controller, allocator, 1, 1, 0);
    controller.advanceStatusSnapshotRevision(allocator);
    var update = try controller.prepareProjection(allocator);
    defer update.deinit(allocator);
    const request_id = switch (update.command orelse return error.ExpectedProjectionCommand) {
        .review_projection => |request| request.id,
        else => return error.ExpectedProjectionCommand,
    };
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expect(page.completed_selection != null);

    controller.rejectProjectionSpawn(allocator, request_id +% 1);
    try std.testing.expect(page.review_projection.pending != null);
    try std.testing.expect(page.completed_selection != null);

    controller.rejectProjectionSpawn(allocator, request_id);
    try std.testing.expect(page.review_projection.pending == null);
    try std.testing.expect(page.completed_selection == null);
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

    page.review_projection.pending = try review_projection.testing.cloneRequest(
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
        .request = try review_projection.testing.cloneRequest(
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

    page.review_projection.pending = try review_projection.testing.cloneRequest(
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
        .request = try review_projection.testing.cloneRequest(
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
        .finished = .{
            .identity = app_page.RequestIdentity.review(0, 1),
            .generation = 1,
            .background_cycle_id = blocked_cycle,
            .result = .{ .failed_static = "blocked" },
        },
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
            .background_cycle_id = accepted_cycle,
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
            .background_cycle_id = failure_cycle,
            .result = .{ .failed = try allocator.dupe(u8, "owned deferred failure") },
        },
    };
    var failure_applied = (try accepted_controller.applyDeferredSource(allocator, false)) orelse return error.ExpectedDeferredApply;
    defer failure_applied.deinit(allocator);
    try std.testing.expect(failure_applied.owned_failure_message != null);
    try std.testing.expectEqualStrings("owned deferred failure", failure_applied.source.auto_reload_failure.?.message);
}

test "superseded deferred source retires exact ownership without publication" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .diff_file = 0 } },
    };
    defer page.deinit(allocator);
    const retained_text = switch (page.load.state) {
        .loaded => |*session| session.loaded.text.ptr,
        else => unreachable,
    };
    page.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = page.auto_reload.beginCycle().?;
    try std.testing.expect(page.auto_reload.markMemberStarted(cycle_id, .source));
    try std.testing.expect(page.auto_reload.moveMember(cycle_id, .source, .deferred_source_apply));
    page.load.generation = 7;
    page.load.pending = .{ .diff_load = 7 };
    const old_epoch = page.repository_read_authority.epoch;
    page.pending_reload = .{ .generation = 7, .read_epoch = old_epoch, .kind = .watch };
    page.deferred_source_apply = .{
        .cycle_id = cycle_id,
        .finished = .{
            .identity = app_page.RequestIdentity.review(0, 1),
            .read_epoch = old_epoch,
            .generation = 7,
            .background_cycle_id = cycle_id,
            .result = .{ .failed_static = "must not publish" },
        },
    };
    page.repository_read_authority.epoch = old_epoch.next();
    page.auto_reload.supersedeActiveCycleByMutation();
    var status_message = @import("../../state.zig").StatusMessage{};
    const controller = testController(&page, &status_message, .unstaged);

    var applied = (try controller.applyDeferredSource(allocator, false)) orelse return error.ExpectedDeferredApply;
    defer applied.deinit(allocator);

    try std.testing.expect(!applied.source.terminal_admitted);
    try std.testing.expectEqual(RedrawDisposition.skip, applied.source.redraw);
    try std.testing.expect(applied.source.auto_reload_failure == null);
    try std.testing.expect(page.deferred_source_apply == null);
    try std.testing.expect(page.load.pending == null);
    try std.testing.expect(page.pending_reload == null);
    try std.testing.expect(page.auto_reload.background_cycle == null);
    try std.testing.expectEqual(retained_text, controller.navigation.view().activeLoadedDiffConst().?.text.ptr);
}
