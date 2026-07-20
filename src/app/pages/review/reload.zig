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
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const load_state = @import("../../load_state.zig");
const projection_component = @import("../../projection_component.zig");
const review_projection = @import("../../review_projection.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");
const review_page = @import("../review.zig");
const review_selection = @import("selection.zig");
const session_hunk_mark = @import("session_hunk_mark.zig");
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

const CombinedToOrdinaryBoundary = struct {
    owner: CombinedToOrdinaryOwner,
    displayed_content: review_selection.ReviewContentToken,
    ordinary_content: review_selection.ReviewContentToken,
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
        return .{
            .owner = owner,
            .displayed_content = displayed_content,
            .ordinary_content = .{
                .repo_epoch = self.repo_epoch,
                .root_identity = self.root_identity,
                .source = review_selection.SourceBasis.init(self.source),
                .source_session_revision = self.page.source_session_revision,
                .display = .{ .loaded = .init(loaded.text) },
            },
        };
    }

    fn rebindCompletedSelectionToOrdinary(
        self: Controller,
        allocator: std.mem.Allocator,
        boundary: CombinedToOrdinaryBoundary,
    ) void {
        const completed = if (self.page.completed_selection) |*completed| completed else return;
        if (completed.token.eql(boundary.displayed_content)) {
            completed.token = boundary.ordinary_content;
        } else if (!completed.token.eql(boundary.ordinary_content)) {
            self.clearCompletedSelection(allocator);
        }
    }

    /// Preserve semantic selection identity across an eager combined rebuild
    /// only when the still-live and incoming presentations are exactly equal.
    /// The fingerprint is a cheap candidate hint; it never authorizes token
    /// transfer by itself. Fresh status/component identity remains attached to
    /// the incoming authority and is intentionally untouched here.
    fn retainCombinedPresentationTokenIfExact(
        self: Controller,
        ready: *review_projection.Ready,
    ) void {
        const incoming = switch (ready.*) {
            .combined_hunks => |*bundle| bundle,
            else => return,
        };
        const live = self.navigation.view().activeCombinedProjection() orelse return;
        if (!live.presentation.fingerprint.eql(incoming.presentation.fingerprint)) return;
        if (!diff_presentation_identity.exactEqual(live.displayFile(), incoming.displayFile())) return;
        incoming.presentation.content_token = live.presentation.content_token;
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
                    self.rebindCompletedSelectionToOrdinary(allocator, boundary);
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
            self.reconcileCompletedSelectionForNoProjectionTarget(allocator);
            if (self.page.pending_display_navigation_restore != null) self.clearDisplayRestore(allocator);
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
                self.retainCombinedPresentationTokenIfExact(&hit.value);
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
        const live_expected_presentation = self.expectedPresentationForTarget(target);
        const primary_reuse_candidate = if (live_expected_presentation) |expected|
            expected.owner == .primary_loaded
        else
            false;
        if (!self.view().displayedMatchesStableIdentity(target)) {
            if (!primary_reuse_candidate) self.clearCompletedSelection(allocator);
            // The first all-unstaged -> combined request has no projection
            // owner to cache or clear. Avoid consuming its eager-retry marker
            // and keep the owned primary selection until exact acceptance or
            // the terminal eager replacement decides its content basis.
            if (!primary_reuse_candidate or self.page.review_projection.hasDisplayed()) {
                self.page.review_projection.cacheOrClearDisplayed(
                    allocator,
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
            self.clearCompletedSelection(allocator);
            return .{};
        };

        // From this point a fresh replacement request is the only terminal
        // which can validate a combined candidate retained across status
        // acceptance. If either owned request clone cannot be constructed,
        // no completion will arrive to reconcile that candidate.
        errdefer self.clearCompletedSelection(allocator);

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
        const pending_id = if (self.page.review_projection.pending) |request| request.id else return;
        if (pending_id != request_id) return;
        self.page.review_projection.clearPending(allocator);
        self.clearCompletedSelection(allocator);
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

        switch (result.result) {
            .ready => |*ready| {
                self.retainCombinedPresentationTokenIfExact(ready);
                self.reconcileCompletedSelectionForReady(allocator, ready);
            },
            .reuse_candidate, .staged_only_reuse_candidate => unreachable,
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
                return try self.applySourceFailure(allocator, pending_reload, std.mem.trim(u8, message, " \t\r\n"));
            },
            .failed_static => |message| {
                _ = self.page.activation.finishMember(finished.identity, .source, .failed);
                return try self.applySourceFailure(allocator, pending_reload, message);
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
        const allocator = self.navigation.loadArenaAllocator() orelse return;
        const previous_path_key = self.navigation.view().selectedStagePathKey();
        const previous_sidebar_identity = self.navigation.view().selectedSidebarIdentity();
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
        .request = try review_projection.cloneRequest(
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
    const request = try review_projection.cloneRequest(
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
        .request = try review_projection.cloneRequest(
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
    const request = try review_projection.cloneRequest(
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
    controller.page.review_projection.pending = try review_projection.cloneRequest(
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
        .request = try review_projection.cloneRequest(
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
    page.status_load.begin(null);
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
    page.status_load.begin(null);
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
        .request = try review_projection.cloneRequest(
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

    const changed_live = &page.review_projection.displayed.ready.value.combined_hunks;
    page.completed_selection = try testCombinedCandidate(controller, allocator, changed_live);
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
        test_combined_before_cached,
        test_combined_before_unstaged,
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
    try std.testing.expectEqual(diff_hunk_projection.HunkStageState.unstaged, authority_view.hunkStageStates()[1]);
    try std.testing.expect(authority_view.hunkActionOrigins()[0] == .cached);
    try std.testing.expect(authority_view.hunkActionOrigins()[1] == .unstaged);

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
    try std.testing.expect(active.hunkStagePresentation().stateForHunk(1) == .unstaged);

    try std.testing.expect(page.completed_selection != null);
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
        .{ .expected_presentation = .{
            .owner = .primary_loaded,
            .fingerprint = mixed_candidate.fingerprint,
            .content_token = .init(page.source_session_revision),
        } },
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
        .request = try review_projection.cloneRequest(
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
