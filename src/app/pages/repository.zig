//! Repository page retained state and synchronous update lifecycle.
//!
//! Rendering composition belongs to `repository/view.zig`; this module owns
//! only state transitions and narrow immutable, authority-gated projections.

const std = @import("std");
const chasen = @import("chasen");
const text_projection = @import("chasen_ui").text_projection;
const keymap = @import("keymap");
const app_direction = @import("../direction.zig");
const app_state = @import("../state.zig");
const drag_auto_scroll = @import("../drag_auto_scroll.zig");
const selection_action = @import("../selection_action.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const page = @import("../page.zig");
const page_link = @import("../page_link.zig");
const git_branch_status = @import("../../git/branch_status.zig");
const git_command = @import("../../git/command.zig");
const git_read = @import("../../git/read.zig");
const process_runner = @import("../../process/runner.zig");
const root_capability = @import("../../repo/root_capability.zig");
const selected_document = @import("../../repository/document.zig");
const source_document = @import("../../repository/source.zig");
const repository_change_map = @import("../../repository/change_map.zig");
const repository_change_index = @import("../../repository/change_index.zig");
const manifest = @import("../../repository/manifest.zig");
const repository_tree = @import("../../repository/tree.zig");
const source_syntax = @import("../../syntax/source.zig");
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");
const repository_branch = @import("repository/branch.zig");
const repository_path_history = @import("repository/path_history.zig");
const repository_tasks = @import("repository/tasks.zig");
const repository_input = @import("repository/input.zig");
const repository_file_search_focus = @import("repository/file_search_focus.zig");
const repository_incoming = @import("repository/incoming.zig");
const repository_layout = @import("repository/layout.zig");
const repository_model = @import("repository/model.zig");
const repository_navigation = @import("repository/navigation.zig");
const repository_selection = @import("repository/selection.zig");
const repository_source_header = @import("repository/source_header.zig");
const repository_source_geometry = @import("repository/source_geometry.zig");
const repository_tree_projection = @import("repository/tree_projection.zig");

const repository_tab_width: usize = 4;
pub const SelectionViewportAnchor = selection_action.ViewportAnchor(usize);

pub const SourceSelectionPresentation = struct {
    pub const Owner = enum { active_keyboard, completed };

    range: repository_selection.Range,
    line_count: usize,
    owner: Owner,
};

pub const LoadState = enum { idle, no_repository, loading, loaded, empty, failed };

pub const DisplayedDocument = struct {
    /// Whether the visible bytes are also usable as current interaction
    /// authority. A retained last-good document remains renderable while
    /// revalidation is pending or has terminally failed, but only an exact
    /// accepted document completion may restore `.accepted`.
    pub const Authority = enum {
        accepted,
        revalidation_required,
    };

    path: []u8,
    manifest_revision: u64,
    source_revision: u64 = 0,
    authority: Authority,
    value: repository_tasks.DocumentValue,
    /// Descriptor-proved metadata for the same regular/symlink snapshot as
    /// `value`. Presentation may omit it while authority is retained, but it
    /// is never refreshed independently from selected-document acceptance.
    metadata: ?selected_document.StableMetadata = null,
    syntax_spans: source_syntax.SourceSpans = .empty(),
    change_decoration: ChangeDecoration = .terminal_plain,

    pub fn deinit(self: *DisplayedDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.value.deinit(allocator);
        self.syntax_spans.deinit(allocator);
        self.change_decoration.deinit(allocator);
        self.* = undefined;
    }
};

/// Explicit async decoration state. `eligible` means the accepted source still
/// needs exactly one comparison; `terminal_plain` is a deliberate fail-closed
/// result, not an invitation to retry on every unrelated event.
pub const ChangeDecoration = union(enum) {
    eligible,
    resolved: repository_change_map.Map,
    terminal_plain,

    pub fn deinit(self: *ChangeDecoration, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resolved => |*resolved| resolved.deinit(allocator),
            .eligible, .terminal_plain => {},
        }
        self.* = .terminal_plain;
    }

    pub fn map(self: *const ChangeDecoration) ?*const repository_change_map.Map {
        return switch (self.*) {
            .resolved => |*resolved| resolved,
            .eligible, .terminal_plain => null,
        };
    }

    pub fn isEligible(self: *const ChangeDecoration) bool {
        return switch (self.*) {
            .eligible => true,
            .resolved, .terminal_plain => false,
        };
    }
};

pub const Msg = union(enum) {
    manifest_finished: repository_tasks.ManifestFinished,
    branch_finished: repository_branch.Finished,
    path_history_finished: repository_path_history.Finished,
    document_finished: repository_tasks.DocumentFinished,
    syntax_finished: repository_tasks.SyntaxFinished,
    change_map_finished: repository_tasks.ChangeMapFinished,
    move_up,
    move_down,
    toggle_directory,
    page_up,
    page_down,
    scroll_left,
    scroll_right,
    mouse_row: usize,
    mouse_toggle_row: usize,
    mouse_source_header_press: repository_layout.BodyPoint,
    mouse_source_press: repository_layout.BodyPoint,
    mouse_owner_drag: ?repository_layout.BodyPoint,
    mouse_owner_release: ?repository_layout.BodyPoint,
    mouse_source_auto_scroll_step: drag_auto_scroll.Step,
    cancel_mouse_owner,
    mouse_source_wheel_up,
    mouse_source_wheel_down,
    focus_tree,
    focus_source,
    toggle_focus,
    tree_first,
    tree_last,
    toggle_tree_visibility,
    decrease_tree_width,
    increase_tree_width,
    source_first,
    source_last,
    toggle_changed_filter,
    toggle_line_numbers,
    enter_source_search,
    cancel_source_search,
    submit_source_search,
    clear_source_search,
    next_source_match,
    previous_source_match,
    source_search_backspace,
    source_search_move_left,
    source_search_move_right,
    source_search_insert: u21,
    source_search_paste: []const u8,
    enter_file_search,
    cancel_file_search,
    submit_file_search,
    file_search_previous,
    file_search_next,
    file_search_backspace,
    file_search_insert: u21,
    file_search_paste: []const u8,
    wheel_up,
    wheel_down,
    selection_action: selection_action.Action,
    selection_owned_noop,
    selection_action_unavailable,
    begin_keyboard_line_selection,
    keyboard_line_selection_move: app_direction.Vertical,

    pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest_finished => |*finished| finished.deinit(allocator),
            .branch_finished => |*finished| finished.deinit(),
            .path_history_finished => |*finished| finished.deinit(allocator),
            .document_finished => |*finished| finished.deinit(allocator),
            .syntax_finished => |*finished| finished.deinit(allocator),
            .change_map_finished => |*finished| finished.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// Repository remains the semantic owner of selected source bytes and raw
/// manifest paths. Commands transfer only separately owned shell effects; App
/// never reconstructs payloads from page state, display text, or coordinates.
pub const Command = union(enum) {
    copy_source_selection: []u8,
    copy_source_header_path: []u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .copy_source_selection, .copy_source_header_path => |text| allocator.free(text),
        }
        self.* = undefined;
    }
};

pub const RepositoryUpdate = struct {
    selected_path_changed: bool = false,
    command: ?Command = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,

    pub fn deinit(self: *RepositoryUpdate, allocator: std.mem.Allocator) void {
        if (self.command) |*command| command.deinit(allocator);
        self.* = .{};
    }

    pub fn takeCommand(self: *RepositoryUpdate) ?Command {
        const command = self.command;
        self.command = null;
        return command;
    }
};

pub const ApplyOutcome = enum { discarded, unchanged, changed, failed };

pub const MouseButton = enum { left, wheel_up, wheel_down };

const SelectionActionHit = union(enum) {
    target: selection_action.Action,
    inert,
};

/// Page-owned state for the read-only current working-tree browser. The zero
/// value allocates nothing and is safe to deinitialize before first activation.
pub const RepositoryPageState = struct {
    initialized: bool = false,
    active: bool = false,
    activation_id: u64 = 0,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    /// Independent read-only branch owner. It shares neither Review's
    /// freshness nor Repository's primary manifest/status diagnostic slot.
    branch: repository_branch.State = .{},
    /// Independent current-selection Git-history owner. It never borrows the
    /// document snapshot or writes Repository's primary diagnostic.
    path_history: repository_path_history.State = .{},
    generation: u64 = 0,
    pending_generation: ?u64 = null,
    manifest_revision: u64 = 0,
    document_generation: u64 = 0,
    pending_document_generation: ?u64 = null,
    /// Basis and generation of the request currently named by
    /// `pending_document_generation`. Its path borrows the accepted manifest,
    /// so every selected-path/manifest replacement clears it first.
    pending_document_request: ?repository_file_search_focus.PendingDocumentRequest = null,
    /// One-shot handoff installed by a successful file-search submit. Content
    /// acceptance remains owned by `applyDocumentFinished`; this value only
    /// decides whether that accepted source may move focus.
    file_search_source_focus: repository_file_search_focus.State = .none,
    source_revision: u64 = 0,
    syntax_generation: u64 = 0,
    pending_syntax_generation: ?u64 = null,
    needs_syntax_request: bool = false,
    change_map_generation: u64 = 0,
    pending_change_map_generation: ?u64 = null,
    needs_change_map_request: bool = false,
    needs_revalidation: bool = false,
    needs_document_revalidation: bool = false,
    freshness: enum { unavailable, validating, fresh, failed } = .unavailable,
    load_state: LoadState = .idle,
    bundle: ?repository_tasks.Bundle = null,
    displayed_document: ?DisplayedDocument = null,
    selected_path: ?[]const u8 = null,
    /// Owned contextual navigation request or bounded unavailable terminal.
    /// Activation/deactivation and manual reload retain it; an explicit newer
    /// destination, repository replacement, or deinit releases it once.
    incoming: repository_incoming.State = .none,
    /// Live pointer owners may borrow accepted page storage. Every focus,
    /// geometry, overlay, repository, manifest, and document replacement path
    /// must cancel this tagged owner before releasing that storage.
    selection_owner: repository_selection.Owner = .none,
    /// Release-frozen source identity, coordinates, and text. Unlike the live
    /// gesture, this owns all storage and never blocks reload or page switches.
    completed_selection: ?repository_selection.CompletedSelection = null,
    file_visibility: repository_tree.Visibility = .all,
    /// Owned raw path captured before entering Changed mode. It is deliberately
    /// independent from manifest generations so background replacement cannot
    /// leave a borrowed selection dangling before the user returns to All.
    all_selection_anchor: ?[]u8 = null,
    /// Page-local root disclosure and typed row projection. The manifest tree
    /// remains root-free and owns only repository-relative entries.
    tree_projection: repository_tree_projection.State = .{},
    viewer: repository_model.ViewerState = .{},
    source_search: repository_model.SourceSearchState = .{},
    file_search: repository_model.FileSearchState = .{},
    status: app_state.StatusMessage = .{},

    fn currentFileSearchFocusBasis(self: *const RepositoryPageState) ?repository_file_search_focus.Basis {
        const root_identity = self.root_identity orelse return null;
        const path = self.selected_path orelse return null;
        return .{
            .repo_epoch = self.repo_epoch,
            .activation_id = self.activation_id,
            .root_identity = root_identity,
            .manifest_revision = self.manifest_revision,
            .path = path,
        };
    }

    /// Close both parts of the pending document owner together. The separate
    /// scalar remains the existing task-admission API; the typed value supplies
    /// the exact basis needed by file-search direct binding.
    fn clearPendingDocumentAuthority(self: *RepositoryPageState) void {
        self.pending_document_generation = null;
        self.pending_document_request = null;
    }

    fn clearPendingDocumentAuthorityIfGeneration(self: *RepositoryPageState, generation: u64) bool {
        if (self.pending_document_generation != generation) return false;
        self.clearPendingDocumentAuthority();
        return true;
    }

    /// Clear borrowed focus/request bases before their selected path or
    /// manifest owner can move or be released.
    fn clearFileSearchDocumentAuthority(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.clearPendingDocumentAuthority();
    }

    pub fn deinit(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.branch.deinit();
        self.path_history.deinit(allocator);
        self.clearFileSearchDocumentAuthority();
        self.incoming.deinit(allocator);
        self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        self.clearCompletedSelection(allocator);
        if (self.bundle) |*bundle| bundle.deinit(allocator);
        if (self.displayed_document) |*document| document.deinit(allocator);
        if (self.all_selection_anchor) |anchor| allocator.free(anchor);
        self.* = .{};
    }

    pub fn activate(self: *RepositoryPageState, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.clearFileSearchDocumentAuthority();
        self.clearLiveSelection();
        self.initialized = true;
        self.active = true;
        self.activation_id +%= 1;
        if (self.activation_id == 0) self.activation_id = 1;
        if (self.repo_epoch != repo_epoch) self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.branch.activate(self.repo_epoch, identity);
        self.path_history.retire(identity != null and self.selected_path != null);
        self.pending_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_document_revalidation = false;
        self.invalidateDisplayedDocumentAuthority();
        // The activation identity changes even when the repository does not,
        // so old manifest/document generations can no longer complete. Rewind
        // the same destination owner to the manifest authority that can name
        // its next valid successor cycle.
        _ = self.incoming.restartManifestCycle();
        if (identity == null) {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            self.load_state = .no_repository;
            _ = self.terminalizeIncoming(.request_failed);
            return;
        }
        self.status.clear();
        self.needs_revalidation = true;
        self.freshness = .validating;
    }

    pub fn deactivate(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.clearLiveSelection();
        self.active = false;
        self.path_history.retire(false);
        if (self.bundle != null) self.freshness = .validating;
    }

    pub fn repositoryChanged(
        self: *RepositoryPageState,
        allocator: ?std.mem.Allocator,
        repo_epoch: u64,
        identity: ?root_capability.Identity,
    ) void {
        self.clearFileSearchDocumentAuthority();
        if (self.incoming != .none) {
            const owner = allocator orelse @panic("Repository incoming replacement requires an allocator");
            self.incoming.dismiss(owner);
        }
        self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        if (self.completed_selection != null) {
            const owner = allocator orelse @panic("Repository completed-selection replacement requires an allocator");
            self.clearCompletedSelection(owner);
        }
        if (self.bundle) |*bundle| {
            const owner = allocator orelse @panic("Repository bundle replacement requires an allocator");
            bundle.deinit(owner);
        }
        self.bundle = null;
        if (self.displayed_document) |*document| {
            const owner = allocator orelse @panic("Repository document replacement requires an allocator");
            document.deinit(owner);
        }
        self.displayed_document = null;
        self.selected_path = null;
        if (self.all_selection_anchor) |anchor| {
            const owner = allocator orelse @panic("Repository selection-anchor replacement requires an allocator");
            owner.free(anchor);
        }
        self.all_selection_anchor = null;
        self.file_visibility = .changed;
        self.tree_projection = .{};
        const retained_tree_width = self.viewer.tree_width;
        const retained_tree_hidden = self.preferredTreeHidden();
        self.viewer = .{
            .focus = if (retained_tree_hidden) .source else .tree,
            .tree_width = retained_tree_width,
            .tree_hidden = retained_tree_hidden,
        };
        self.source_search.clear();
        self.file_search.close();
        self.pending_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.branch.repositoryChanged(self.active, identity);
        if (allocator) |owner|
            self.path_history.invalidate(owner, false)
        else
            self.path_history.retire(false);
        self.status.clear();
        self.load_state = if (identity != null) .idle else .no_repository;
        self.freshness = if (identity != null) .validating else .unavailable;
        self.needs_revalidation = self.active and identity != null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
    }

    /// Infallible owner-installation half of the shell's two-phase transition.
    /// Identity-dependent resolution must wait until Repository activation has
    /// installed the current repo epoch/root under the approved commit order.
    pub fn acceptIncoming(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        self.incoming.accept(allocator, incoming);
    }

    pub fn dismissIncoming(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.incoming.dismiss(allocator);
    }

    pub fn incomingIsPending(self: *const RepositoryPageState) bool {
        return self.incoming.isPending();
    }

    pub fn incomingUnavailable(self: *const RepositoryPageState) ?*const page_link.RepositoryUnavailable {
        return self.incoming.unavailableValue();
    }

    /// Export only a resolved, page-owned exact path for synchronous Review
    /// lookup. A pending or unavailable contextual destination wins over any
    /// older retained selection and therefore exports no context.
    pub fn reviewTarget(self: *const RepositoryPageState) page_link.RepositoryReviewTarget {
        if (self.incoming != .none) return .no_context;
        const path = self.selected_path orelse return .no_context;
        const identity = self.root_identity orelse return .no_context;
        return .{ .location = .{
            .repo_epoch = self.repo_epoch,
            .root_identity = identity,
            .path = path,
        } };
    }

    pub fn terminalizeIncoming(self: *RepositoryPageState, reason: page_link.RepositoryUnavailableReason) bool {
        return self.incoming.terminalize(reason);
    }

    /// Continue a newly committed owner only after `activate` establishes the
    /// destination identity. The shell calls this allocation-free operation
    /// after its owner-move/deactivate/activate sequence; accepted async
    /// manifest completions use the same resolver while inactive or active.
    pub fn resolveIncomingAfterActivation(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
    ) bool {
        std.debug.assert(self.active);
        return self.resolveIncomingManifest(allocator, body_size);
    }

    /// Resolve only against the full accepted manifest. Normal Repository
    /// restoration is intentionally not reused because it may choose a nearby
    /// file when the preferred path is absent. An explicit cross-page target
    /// either selects the byte-exact file or becomes unavailable.
    fn resolveIncomingManifest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
    ) bool {
        const location = if (self.incoming.manifestIntent()) |intent| intent.* else return false;
        const active_root = self.root_identity orelse {
            return self.incoming.terminalize(.request_failed);
        };
        if (location.repo_epoch != self.repo_epoch or !location.root_identity.eql(active_root)) {
            return self.incoming.terminalize(.request_failed);
        }

        const bundle = if (self.bundle) |*owned| owned else return false;
        const exact_path = bundle.tree.filePath(location.path, .all) orelse {
            return self.incoming.terminalize(.path_not_found);
        };
        const node_index = bundle.tree.nodeIndexForPath(exact_path, .all) orelse {
            return self.incoming.terminalize(.request_failed);
        };

        if (self.file_visibility == .changed and bundle.tree.filePath(exact_path, .changed) == null) {
            self.file_visibility = .all;
            if (self.all_selection_anchor) |anchor| allocator.free(anchor);
            self.all_selection_anchor = null;
            bundle.tree.rebuildVisibleFor(.all);
            if (self.file_search.mode) {
                self.refreshFileSearch();
            }
            self.status.set("Review target opened in All files", .{});
        }

        const visible_index = self.tree_projection.revealManifestNode(
            &bundle.tree,
            self.file_visibility,
            node_index,
        ) orelse {
            return self.incoming.terminalize(.request_failed);
        };
        const matching_document = if (self.displayed_document) |*displayed|
            displayed.manifest_revision == self.manifest_revision and std.mem.eql(u8, displayed.path, exact_path)
        else
            false;

        if (!optionalPathEql(self.selected_path, exact_path)) {
            self.clearFileSearchDocumentAuthority();
            self.path_history.invalidate(allocator, true);
        }
        self.selected_path = exact_path;
        self.viewer.tree_cursor = visible_index;
        self.placeIncomingTreeForBodySize(body_size);
        if (!matching_document) {
            self.invalidateSelectedDocument(allocator);
        }
        const advanced = self.incoming.advanceToDocument(self.manifest_revision);
        std.debug.assert(advanced);
        _ = self.resolveIncomingDocument(allocator, null);
        return true;
    }

    /// Consume only the accepted source named by the document-stage owner.
    /// `accepted_generation == null` is the no-task case where Repository
    /// already displayed the exact manifest/path before this transition.
    fn resolveIncomingDocument(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        accepted_generation: ?u64,
    ) bool {
        const pending = if (self.incoming.documentIntent()) |document| document.* else return false;
        const active_root = self.root_identity orelse {
            return self.incoming.terminalize(.request_failed);
        };
        if (pending.location.repo_epoch != self.repo_epoch or
            !pending.location.root_identity.eql(active_root))
        {
            return self.incoming.terminalize(.request_failed);
        }
        if (pending.manifest_revision != self.manifest_revision) return false;
        const selected = self.selected_path orelse return false;
        if (!std.mem.eql(u8, pending.location.path, selected)) return false;
        if (accepted_generation) |generation| {
            if (pending.document_generation != generation) return false;
        } else {
            if (pending.document_generation != null) return false;
            if (self.acceptedCurrentSourceForSelection() == null) return false;
        }

        const displayed = if (self.displayed_document) |*document| document else return false;
        if (displayed.manifest_revision != pending.manifest_revision or
            !std.mem.eql(u8, displayed.path, pending.location.path)) return false;
        switch (displayed.value) {
            .source => |*source| {
                if (pending.location.line) |one_based_line| {
                    const requested: usize = if (one_based_line > 0) @intCast(one_based_line - 1) else 0;
                    const line_index = @min(requested, source.rowCount() - 1);
                    self.viewer.focus = .source;
                    self.viewer.source_cursor = line_index;
                    // The next frame clamps this against the real viewport;
                    // keeping the cursor as the provisional top row makes the
                    // accepted location visible even before that geometry pass.
                    self.viewer.source_vertical_scroll = line_index;
                } else if (accepted_generation != null) {
                    // A newly accepted target opens its source. Reusing an
                    // already displayed path with no line is intentionally a
                    // no-op under the approved same-target UX contract.
                    self.viewer.focus = .source;
                }
                const completed = self.incoming.completeDocument(allocator);
                std.debug.assert(completed);
                return true;
            },
            .inert => return self.incoming.terminalize(.source_unavailable),
        }
    }

    fn applyIncomingManifestResolution(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        outcome: ApplyOutcome,
        body_size: chasen.Size,
    ) ApplyOutcome {
        if (!self.resolveIncomingManifest(allocator, body_size)) return outcome;
        return switch (outcome) {
            .unchanged => .changed,
            .discarded, .changed, .failed => outcome,
        };
    }

    /// Classify a manifest completion which cannot be accepted by the current
    /// request identity. A contextual destination may remain pending only when
    /// an explicitly named successor can still resolve it: the current task, a
    /// scheduled revalidation, or reactivation of an inactive page. Without
    /// one of those successors, retaining `awaiting_manifest` would create an
    /// unbounded owner, so the destination moves to its request-failed terminal.
    fn manifestOwnerHasSuccessor(self: *const RepositoryPageState) bool {
        const current_task_can_advance = if (self.pending_generation) |pending|
            pending == self.generation
        else
            false;
        const scheduled_successor = self.active and self.root_identity != null and self.needs_revalidation;
        const dormant_successor = !self.active;
        return current_task_can_advance or scheduled_successor or dormant_successor;
    }

    /// A document-stage destination may outlive a rejected completion only
    /// when another explicit authority can still settle it. Inactive state is
    /// a named successor because activation rewinds the owner to manifest
    /// authority. Active state instead requires the exact current selection
    /// basis plus either its bound task or a request the page can start next.
    fn documentOwnerHasSuccessor(
        self: *const RepositoryPageState,
        pending: *const repository_incoming.AwaitingDocument,
    ) bool {
        if (!self.active) return true;

        const root = self.root_identity orelse return false;
        const selected = self.selected_path orelse return false;
        if (pending.location.repo_epoch != self.repo_epoch or
            !pending.location.root_identity.eql(root) or
            pending.manifest_revision != self.manifest_revision or
            !std.mem.eql(u8, pending.location.path, selected))
        {
            return false;
        }

        const current_task_can_advance = if (pending.document_generation) |bound|
            self.document_generation == bound and self.pending_document_generation == bound
        else
            false;
        return current_task_can_advance or self.wantsDocumentRequest();
    }

    /// Apply liveness to the owner which remains after a rejected completion,
    /// not to the completion's stage. A stale document result may coexist with
    /// an awaiting-manifest owner after reload; that owner is retained only if
    /// its own manifest authority names a successor.
    fn terminalizeIncomingOwnerWithoutSuccessor(self: *RepositoryPageState) bool {
        const has_successor = switch (self.incoming) {
            .awaiting_manifest => self.manifestOwnerHasSuccessor(),
            .awaiting_document => |*pending| self.documentOwnerHasSuccessor(pending),
            .none, .unavailable => return false,
        };
        if (has_successor) return false;
        const terminalized = self.terminalizeIncoming(.request_failed);
        std.debug.assert(terminalized);
        return true;
    }

    fn classifyMismatchedManifestFinished(self: *RepositoryPageState) ApplyOutcome {
        return if (self.terminalizeIncomingOwnerWithoutSuccessor()) .failed else .discarded;
    }

    fn classifyMismatchedDocumentFinished(self: *RepositoryPageState) ApplyOutcome {
        return if (self.terminalizeIncomingOwnerWithoutSuccessor()) .failed else .discarded;
    }

    pub fn prepareRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !repository_tasks.Request {
        // A manifest attempt supersedes pane-focus handoff immediately, but a
        // descriptor-allocation failure must not revoke the still-valid
        // predecessor document task. Close that pending owner only after all
        // fallible request preparation has succeeded below.
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        self.path_history.retire(false);
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending_generation = self.generation;
        self.clearPendingDocumentAuthority();
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_revalidation = false;
        self.freshness = .validating;
        if (self.bundle != null) self.status.set("Validating repository...", .{});
        if (self.bundle == null) self.load_state = .loading;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.generation,
            .root_path = owned_root,
            .root = root,
            .expected_fingerprint = if (self.bundle) |*bundle| bundle.document.fingerprint else null,
            .expected_status_fingerprint = if (self.bundle) |*bundle| bundle.status_fingerprint else null,
        };
    }

    pub fn wantsBranchRequest(self: *const RepositoryPageState) bool {
        return self.branch.wantsRequest(self.active, self.root_identity);
    }

    pub fn prepareBranchRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !repository_branch.Request {
        return self.branch.prepareRequest(
            allocator,
            .{
                .origin = .repository,
                .repo_epoch = self.repo_epoch,
                .activation_id = self.activation_id,
            },
            repo_root,
            capability,
        );
    }

    pub fn markBranchRequestPreparationFailed(self: *RepositoryPageState) void {
        self.branch.markPreparationFailed();
    }

    pub fn rejectBranchSpawn(self: *RepositoryPageState, generation: u64) void {
        self.branch.rejectSpawn(generation);
    }

    pub fn applyBranchFinished(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        finished: *repository_branch.Finished,
    ) repository_branch.ApplyOutcome {
        const outcome = self.branch.applyFinished(
            .{
                .origin = .repository,
                .repo_epoch = self.repo_epoch,
                .activation_id = self.activation_id,
            },
            self.root_identity,
            self.active,
            finished,
        );
        switch (outcome) {
            .changed, .unchanged => if (self.freshBranchBasis()) |basis| {
                if (self.path_history.reconcileFreshBranchBasis(
                    allocator,
                    basis,
                    self.active and self.selected_path != null,
                )) return .changed;
            },
            .discarded, .failed => {},
        }
        return outcome;
    }

    fn requestIdentity(self: *const RepositoryPageState) page.RequestIdentity {
        return .{
            .origin = .repository,
            .repo_epoch = self.repo_epoch,
            .activation_id = self.activation_id,
        };
    }

    fn freshBranchBasis(self: *const RepositoryPageState) ?repository_path_history.FreshHeadBasis {
        switch (self.branch.freshness) {
            .fresh => {},
            .unavailable, .validating, .failed => return null,
        }
        const root = self.root_identity orelse return null;
        if (!self.branch.snapshot.matches(.{ .repo_epoch = self.repo_epoch, .root_identity = root })) return null;
        const status = self.branch.snapshot.status;
        if (status.oid) |oid| return .{ .oid = oid };
        return switch (status.head) {
            .branch => .unborn,
            .detached, .unknown => null,
        };
    }

    pub fn wantsPathHistoryRequest(self: *const RepositoryPageState) bool {
        return self.path_history.wantsRequest(self.active, self.root_identity, self.selected_path) and
            self.pending_generation == null;
    }

    pub fn preparePathHistoryRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !repository_path_history.Request {
        const path = self.selected_path orelse return error.NoSelectedPath;
        return self.path_history.prepareRequest(
            allocator,
            self.requestIdentity(),
            self.manifest_revision,
            repo_root,
            path,
            capability,
        );
    }

    pub fn markPathHistoryRequestPreparationFailed(self: *RepositoryPageState) void {
        self.path_history.markPreparationFailed();
    }

    pub fn rejectPathHistorySpawn(self: *RepositoryPageState, generation: u64) void {
        self.path_history.rejectSpawn(generation);
    }

    pub fn applyPathHistoryFinished(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        finished: *repository_path_history.Finished,
    ) repository_path_history.ApplyOutcome {
        return self.path_history.applyFinished(
            allocator,
            self.requestIdentity(),
            self.root_identity,
            self.manifest_revision,
            self.selected_path,
            self.active,
            self.freshBranchBasis(),
            finished,
        );
    }

    pub fn prepareDocumentRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
    ) !repository_tasks.DocumentRequest {
        const selected = self.selected_path orelse return error.NoSelectedDocument;
        // Request preparation transfers authority away from retained visible
        // bytes before allocation/spawn can fail. Only the matching accepted
        // completion below may restore it.
        self.invalidateDisplayedDocumentAuthority();
        const path = try allocator.dupe(u8, selected);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.document_generation +%= 1;
        if (self.document_generation == 0) self.document_generation = 1;
        self.pending_document_generation = self.document_generation;
        const pending_request: repository_file_search_focus.PendingDocumentRequest = .{
            .basis = .{
                .repo_epoch = self.repo_epoch,
                .activation_id = self.activation_id,
                // Record the descriptor's root, independently from current
                // page authority, so direct binding must prove they agree.
                .root_identity = root.identity,
                .manifest_revision = self.manifest_revision,
                .path = selected,
            },
            .generation = self.document_generation,
        };
        self.pending_document_request = pending_request;
        _ = self.file_search_source_focus.bindPrepared(pending_request);
        self.needs_document_revalidation = false;
        if (self.incoming.documentIntent() != null) {
            const bound = self.incoming.bindDocumentGeneration(
                self.manifest_revision,
                selected,
                self.document_generation,
            );
            std.debug.assert(bound);
        }
        if (self.displayed_document != null) self.status.set("Validating selected file...", .{});
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.document_generation,
            .manifest_revision = self.manifest_revision,
            .path = path,
            .root = root,
        };
    }

    pub fn prepareSyntaxRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
    ) !repository_tasks.SyntaxRequest {
        if (!source_syntax_runtime.enabled) return error.SyntaxProviderDisabled;
        const displayed = self.displayed_document orelse return error.NoDisplayedSource;
        const source = switch (displayed.value) {
            .source => |source| source,
            .inert => return error.NoDisplayedSource,
        };
        const path = try allocator.dupe(u8, displayed.path);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.syntax_generation +%= 1;
        if (self.syntax_generation == 0) self.syntax_generation = 1;
        self.pending_syntax_generation = self.syntax_generation;
        self.needs_syntax_request = false;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.syntax_generation,
            .manifest_revision = displayed.manifest_revision,
            .source_revision = displayed.source_revision,
            .expected_fingerprint = source.fingerprint,
            .path = path,
            .root = root,
        };
    }

    pub fn prepareChangeMapRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
        temp_base_path: []const u8,
    ) !repository_tasks.ChangeMapRequest {
        const displayed = self.displayed_document orelse return error.NoDisplayedSource;
        const source = switch (displayed.value) {
            .source => |source| source,
            .inert => return error.NoDisplayedSource,
        };
        if (!displayed.change_decoration.isEligible()) return error.ChangeMapNotEligible;
        const path = try allocator.dupe(u8, displayed.path);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        const owned_temp_base = try allocator.dupe(u8, temp_base_path);
        errdefer allocator.free(owned_temp_base);
        self.change_map_generation +%= 1;
        if (self.change_map_generation == 0) self.change_map_generation = 1;
        self.pending_change_map_generation = self.change_map_generation;
        self.needs_change_map_request = false;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.change_map_generation,
            .manifest_revision = displayed.manifest_revision,
            .source_revision = displayed.source_revision,
            .expected_fingerprint = source.fingerprint,
            .expected_content_line_count = source.contentLineCount(),
            .path = path,
            .root = root,
            .temp_base_path = owned_temp_base,
        };
    }

    /// Task allocation/spawn rejects synchronously after one generation was
    /// prepared. Only that exact generation may close its incoming owner; a
    /// stale rejection must not consume a newer successor.
    pub fn rejectSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_generation != generation) return;
        self.pending_generation = null;
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not start repository manifest task", .{});
        _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn rejectDocumentSpawn(self: *RepositoryPageState, generation: u64) void {
        if (!self.clearPendingDocumentAuthorityIfGeneration(generation)) return;
        self.invalidateDisplayedDocumentAuthority();
        _ = self.file_search_source_focus.clearGeneration(generation);
        self.status.set("Could not start selected file task", .{});
        const pending = self.incoming.documentIntent() orelse return;
        if (pending.document_generation == generation) {
            _ = self.terminalizeIncoming(.request_failed);
        }
    }

    pub fn rejectSyntaxSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_syntax_generation != generation) return;
        self.pending_syntax_generation = null;
        // Task-start failure is transient and occurs before a provider verdict.
        // Preserve intent for a later event; maybeStart... is called only once
        // per update, so this does not create an immediate retry loop.
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
    }

    pub fn rejectChangeMapSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_change_map_generation != generation) return;
        self.pending_change_map_generation = null;
        self.needs_change_map_request = self.currentSource() != null;
    }

    pub fn requestReload(self: *RepositoryPageState, has_repository: bool) void {
        // The shared authority transition clears borrowed source storage and
        // preserves the semantic viewport across any projection change.
        if (self.selection_owner.activeSourceHeader() != null) self.cancelMouseOwner();
        self.path_history.retire(false);
        self.branch.requestReload(
            self.active,
            self.repo_epoch,
            if (has_repository) self.root_identity else null,
        );
        self.clearFileSearchDocumentAuthority();
        self.invalidateDisplayedDocumentAuthority();
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        if (!has_repository) {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            self.load_state = .no_repository;
            self.status.set("Repository required", .{});
            _ = self.terminalizeIncoming(.request_failed);
            return;
        }
        // Manual reload invalidates any selected-file generation. Re-resolve
        // the retained exact path against the accepted successor manifest
        // before a new document generation may bind to it.
        _ = self.incoming.restartManifestCycle();
        self.needs_revalidation = true;
    }

    pub fn wantsManifestRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_revalidation;
    }

    pub fn wantsDocumentRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_document_revalidation and
            self.pending_generation == null and self.pending_document_generation == null and
            self.selected_path != null and self.root_identity != null;
    }

    pub fn wantsSyntaxRequest(self: *const RepositoryPageState) bool {
        return source_syntax_runtime.enabled and self.active and self.needs_syntax_request and
            self.pending_generation == null and self.pending_document_generation == null and
            self.pending_syntax_generation == null and self.displayed_document != null and
            self.root_identity != null;
    }

    pub fn wantsChangeMapRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_change_map_request and
            self.pending_generation == null and self.pending_document_generation == null and
            self.pending_change_map_generation == null and self.displayed_document != null and
            self.root_identity != null;
    }

    pub fn markRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not prepare repository manifest: {s}", .{@errorName(err)});
        // This attempt has no descriptor, but manual reload may have left the
        // current predecessor task acceptable. Retain the destination while
        // that exact generation can still advance it.
        const predecessor_can_advance = if (self.pending_generation) |pending|
            pending == self.generation
        else
            false;
        if (!predecessor_can_advance) _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn markDocumentRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        self.status.set("Could not prepare selected file: {s}", .{@errorName(err)});
        _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn markDocumentCapabilityUnavailable(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        // Capability lookup used to be an inert retry edge for ordinary
        // browsing. Only a committed contextual destination converts it into
        // a bounded destination-page terminal.
        if (self.incoming.documentIntent() == null) return;
        self.needs_document_revalidation = false;
        self.status.set("Repository root changed", .{});
        // App orchestration reaches this only after the page committed a
        // destination but the root capability vanished before task creation.
        _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn markSyntaxRequestPreparationFailed(self: *RepositoryPageState) void {
        self.pending_syntax_generation = null;
        // Preparation failure has the same retry semantics as spawn failure.
        // Parser/query/metadata failure is different: its delivered completion
        // consumes intent and deliberately leaves the plain source terminal.
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
    }

    pub fn markChangeMapRequestPreparationFailed(self: *RepositoryPageState) void {
        self.pending_change_map_generation = null;
        self.needs_change_map_request = self.currentSource() != null;
    }

    pub fn repositoryCommitFailed(self: *RepositoryPageState) void {
        if (self.bundle == null) self.load_state = .failed;
        self.freshness = .failed;
        self.status.set("Repository root could not be opened safely", .{});
    }

    pub fn applyFinished(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        finished: *repository_tasks.ManifestFinished,
        body_size: chasen.Size,
    ) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.generation or
            self.pending_generation != finished.generation)
        {
            return self.classifyMismatchedManifestFinished();
        }
        self.pending_generation = null;
        const expected_root = self.root_identity orelse {
            self.acceptFailure("Repository root changed");
            _ = self.terminalizeIncoming(.request_failed);
            return .failed;
        };
        if (!expected_root.eql(finished.root_identity)) {
            self.acceptFailure("Repository root changed");
            _ = self.terminalizeIncoming(.request_failed);
            return .failed;
        }
        switch (finished.result) {
            .unchanged => {
                const changed_status_message = self.file_visibility == .changed and
                    self.bundle != null and !self.bundle.?.status_available;
                self.freshness = if (self.active) .fresh else .validating;
                self.requireDocumentRevalidation();
                self.path_history.invalidate(allocator, self.selected_path != null);
                self.status.clear();
                return self.applyIncomingManifestResolution(
                    allocator,
                    if (changed_status_message) .changed else .unchanged,
                    body_size,
                );
            },
            .status_changed => |*update| {
                const bundle = if (self.bundle) |*owned| owned else {
                    // A status-only completion is only valid against a retained
                    // manifest. Treat an impossible orphan as optional loss;
                    // its owned payload remains with `finished.deinit`.
                    self.freshness = if (self.active) .fresh else .validating;
                    self.status.clear();
                    return self.applyIncomingManifestResolution(allocator, .unchanged, body_size);
                };
                const previous_selected = self.selected_path;
                const previous_status_available = bundle.status_available;
                const visible_changed = switch (update.*) {
                    .loaded => |*index| blk: {
                        const changed = bundle.tree.applyChangeIndex(index);
                        bundle.status_fingerprint = index.fingerprint;
                        bundle.status_available = true;
                        index.deinit(allocator);
                        update.* = .unavailable;
                        break :blk changed;
                    },
                    .unavailable => blk: {
                        bundle.status_fingerprint = null;
                        bundle.status_available = false;
                        break :blk bundle.tree.clearChangeIndex();
                    },
                };
                const selection_changed = if (self.file_visibility == .changed)
                    self.rebuildTreeProjection(previous_selected, false, 0)
                else
                    false;
                // Status-only refresh does not change manifest/source identity,
                // but Changed projection may move or clear selection when a file
                // leaves the status set. Preserve the source only when its raw
                // path identity survived that projection.
                if (selection_changed) {
                    self.invalidateSelectedDocument(allocator);
                    self.path_history.invalidate(allocator, self.selected_path != null);
                } else self.requireDocumentRevalidation();
                if (!selection_changed) self.path_history.invalidate(allocator, self.selected_path != null);
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                const status_availability_changed = self.file_visibility == .changed and
                    previous_status_available != bundle.status_available;
                const changed_status_message = self.file_visibility == .changed and !bundle.status_available;
                return self.applyIncomingManifestResolution(
                    allocator,
                    if (visible_changed or selection_changed or status_availability_changed or changed_status_message) .changed else .unchanged,
                    body_size,
                );
            },
            .loaded => |*incoming| {
                self.replaceBundle(allocator, incoming) catch |err| {
                    self.acceptFailure(@errorName(err));
                    _ = self.terminalizeIncoming(.request_failed);
                    return .failed;
                };
                finished.result = .{ .unchanged = self.bundle.?.document.fingerprint };
                self.manifest_revision +%= 1;
                if (self.manifest_revision == 0) self.manifest_revision = 1;
                self.pending_syntax_generation = null;
                self.pending_change_map_generation = null;
                self.needs_syntax_request = false;
                self.needs_change_map_request = false;
                self.needs_document_revalidation = self.selected_path != null;
                self.path_history.invalidate(allocator, self.selected_path != null);
                if (self.displayed_document) |*document| document.deinit(allocator);
                self.displayed_document = null;
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                return self.applyIncomingManifestResolution(allocator, .changed, body_size);
            },
            .failed_static => |message| {
                self.acceptFailure(message);
                _ = self.terminalizeIncoming(.request_failed);
                return .failed;
            },
        }
    }

    pub fn applyDocumentFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *repository_tasks.DocumentFinished) ApplyOutcome {
        const completion_owns_pending = finished.identity.origin == .repository and
            finished.identity.repo_epoch == self.repo_epoch and
            finished.identity.activation_id == self.activation_id and
            self.pending_document_generation == finished.generation;
        if (!completion_owns_pending or
            finished.generation != self.document_generation or
            finished.manifest_revision != self.manifest_revision)
        {
            // A delivered completion is the terminal event for the exact task
            // identity it owns even when its accepted manifest basis is now
            // stale. It cannot remain named as a future successor.
            if (completion_owns_pending) {
                _ = self.clearPendingDocumentAuthorityIfGeneration(finished.generation);
                _ = self.file_search_source_focus.clearGeneration(finished.generation);
            }
            return self.classifyMismatchedDocumentFinished();
        }
        const cleared_pending = self.clearPendingDocumentAuthorityIfGeneration(finished.generation);
        std.debug.assert(cleared_pending);
        const expected_root = self.root_identity orelse {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            _ = self.terminalizeIncomingOwnerWithoutSuccessor();
            return .failed;
        };
        if (!expected_root.eql(finished.root_identity)) {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            self.status.set("Repository root changed", .{});
            _ = self.terminalizeIncomingOwnerWithoutSuccessor();
            return .failed;
        }
        const selected = self.selected_path orelse {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            return self.classifyMismatchedDocumentFinished();
        };
        if (!std.mem.eql(u8, selected, finished.path)) {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            return self.classifyMismatchedDocumentFinished();
        }

        const previous_source = self.currentSource();
        const viewport_anchor = if (previous_source) |document|
            if (self.completed_selection != null) self.captureSourceViewportAnchor(document) else null
        else
            null;

        // Every live source range borrows the displayed document and must end
        // before its storage is replaced. A completed candidate is independent
        // owned state: retain it only when the incoming document proves the
        // same complete semantic content token. Delivery generations and the
        // replacement allocation itself are intentionally irrelevant.
        self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        self.reconcileCompletedSelectionForDocument(allocator, finished);
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.source_revision +%= 1;
        if (self.source_revision == 0) self.source_revision = 1;
        if (self.displayed_document) |*previous| previous.deinit(allocator);
        self.displayed_document = .{
            .path = finished.path,
            .manifest_revision = finished.manifest_revision,
            .source_revision = self.source_revision,
            .authority = .accepted,
            .value = finished.value,
            .metadata = finished.metadata,
            .change_decoration = switch (finished.value) {
                .source => .eligible,
                .inert => .terminal_plain,
            },
        };
        finished.path = &.{};
        finished.value = .{ .inert = .unreadable };
        finished.metadata = null;
        self.viewer.resetSource();
        self.reconcileNoSourceFocus();
        if (viewport_anchor) |anchor| if (self.currentSource()) |document| {
            // Coordinator clamps against the real frame geometry after this
            // allocation-free semantic restore. Zero visible rows deliberately
            // avoid inventing a terminal height inside the page owner.
            self.restoreSourceViewportAnchor(anchor, document, 0);
        };
        self.source_search.clear();
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
        self.needs_change_map_request = self.currentSource() != null;
        self.status.clear();
        self.resolveFileSearchSourceFocus(finished.generation);
        _ = self.resolveIncomingDocument(allocator, finished.generation);
        // A completion may be valid for the ordinary selected source while an
        // inconsistent contextual owner names a different revision/generation.
        // Keep the accepted source, but never leave that owner unbounded.
        _ = self.terminalizeIncomingOwnerWithoutSuccessor();
        return .changed;
    }

    /// Move focus only after the ordinary document admission path has installed
    /// an accepted source for the exact bound Repository basis. Inert content is
    /// an accepting document terminal but cannot own source focus.
    fn resolveFileSearchSourceFocus(self: *RepositoryPageState, generation: u64) void {
        if (self.currentSource() == null) {
            _ = self.file_search_source_focus.clearGeneration(generation);
            return;
        }
        const basis = self.currentFileSearchFocusBasis() orelse return;
        if (self.file_search_source_focus.consumeAccepted(basis, generation)) {
            self.viewer.focus = .source;
        }
    }

    pub fn applySyntaxFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *repository_tasks.SyntaxFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.syntax_generation or
            self.pending_syntax_generation != finished.generation or
            finished.manifest_revision != self.manifest_revision)
        {
            return .discarded;
        }
        self.pending_syntax_generation = null;
        const expected_root = self.root_identity orelse return .discarded;
        if (!expected_root.eql(finished.root_identity)) return .discarded;
        const displayed = if (self.displayed_document) |*document| document else return .discarded;
        if (displayed.source_revision != finished.source_revision or
            displayed.manifest_revision != finished.manifest_revision or
            !std.mem.eql(u8, displayed.path, finished.path)) return .discarded;
        const source = switch (displayed.value) {
            .source => |*source| source,
            .inert => return .discarded,
        };
        if (!source.fingerprint.eql(finished.fingerprint)) return .discarded;
        switch (finished.result) {
            .loaded => |spans| {
                displayed.syntax_spans.deinit(allocator);
                displayed.syntax_spans = spans;
                finished.result = .unavailable;
                return .changed;
            },
            .unavailable => return .unchanged,
        }
    }

    pub fn applyChangeMapFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *repository_tasks.ChangeMapFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.change_map_generation or
            self.pending_change_map_generation != finished.generation or
            finished.manifest_revision != self.manifest_revision)
        {
            return .discarded;
        }
        self.pending_change_map_generation = null;
        const expected_root = self.root_identity orelse return .discarded;
        if (!expected_root.eql(finished.root_identity)) return .discarded;
        const displayed = if (self.displayed_document) |*document| document else return .discarded;
        if (displayed.source_revision != finished.source_revision or
            displayed.manifest_revision != finished.manifest_revision or
            !std.mem.eql(u8, displayed.path, finished.path)) return .discarded;
        const source = switch (displayed.value) {
            .source => |*source| source,
            .inert => return .discarded,
        };
        if (!source.fingerprint.eql(finished.fingerprint) or
            source.contentLineCount() != finished.content_line_count)
        {
            // The independent task snapshot observed a newer file than the
            // accepted source. Do not attach its rows to old coordinates;
            // request a fresh primary document before trying decoration again.
            self.requireDocumentRevalidation();
            return .discarded;
        }
        if (!displayed.change_decoration.isEligible()) return .discarded;

        displayed.change_decoration.deinit(allocator);
        switch (finished.result) {
            .loaded => |map| {
                displayed.change_decoration = .{ .resolved = map };
                finished.result = .unavailable;
                return .changed;
            },
            .unavailable => {
                displayed.change_decoration = .terminal_plain;
                return .unchanged;
            },
        }
    }

    fn replaceBundle(self: *RepositoryPageState, allocator: std.mem.Allocator, incoming: *repository_tasks.Bundle) !void {
        self.clearFileSearchDocumentAuthority();
        self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        const previous_selected = self.selected_path;
        const previous_cursor_identity = if (self.bundle) |*previous|
            self.tree_projection.cursorIdentity(&previous.tree, self.viewer.tree_cursor)
        else
            null;
        var selected = if (self.bundle) |*previous|
            try incoming.tree.restoreStateFrom(allocator, &previous.tree, previous_selected)
        else
            incoming.tree.firstFilePath();

        incoming.tree.rebuildVisibleFor(self.file_visibility);
        if (self.file_visibility == .changed) {
            const status_usable = incoming.status_available;
            const retained = if (status_usable and selected != null)
                incoming.tree.filePath(selected.?, .changed)
            else
                null;
            selected = retained orelse if (status_usable)
                incoming.tree.firstFilePathFor(.changed)
            else
                null;
        }
        // Resolve the borrowed predecessor identity before freeing its owner.
        // An invalid predecessor cursor explicitly falls back to the selected
        // incoming file when visible, then to the typed root.
        const next_cursor = if (previous_cursor_identity) |identity|
            self.tree_projection.cursorForIdentity(&incoming.tree, self.file_visibility, identity)
        else if (selected) |path|
            self.projectedCursorForPath(&incoming.tree, path) orelse 0
        else
            0;

        // A newly accepted manifest does not yet provide a complete selected
        // source fingerprint, so it cannot prove candidate identity.
        self.clearCompletedSelection(allocator);
        if (self.bundle) |*previous| previous.deinit(allocator);
        self.bundle = incoming.*;
        incoming.* = undefined;
        self.selected_path = selected;
        self.load_state = if (self.bundle.?.document.paths.len == 0) .empty else .loaded;
        self.viewer.tree_cursor = next_cursor;
        if (selected == null) self.reconcileNoSourceFocus();
        if (self.file_search.mode) {
            self.refreshFileSearch();
        }
        self.clampScroll(0);
    }

    /// Rebuilds only the page-visible tree and resolves selection against that
    /// projection. The raw manifest and collapse flags remain authoritative;
    /// switching filters therefore cannot destroy the user's All-mode shape.
    fn rebuildTreeProjection(
        self: *RepositoryPageState,
        preferred: ?[]const u8,
        reveal_preferred: bool,
        body_height: u16,
    ) bool {
        const previous = self.selected_path;
        const bundle = if (self.bundle) |*owned| owned else {
            if (previous != null) self.clearFileSearchDocumentAuthority();
            self.selected_path = null;
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            self.file_search.resetResults();
            return !optionalPathEql(previous, null);
        };
        const tree = &bundle.tree;
        const cursor_identity = self.tree_projection.cursorIdentity(tree, self.viewer.tree_cursor);
        tree.rebuildVisibleFor(self.file_visibility);

        const status_usable = self.file_visibility == .all or bundle.status_available;
        const retained = if (status_usable and preferred != null)
            tree.filePath(preferred.?, self.file_visibility)
        else
            null;
        const selected = retained orelse if (status_usable)
            tree.firstFilePathFor(self.file_visibility)
        else
            null;
        if (!optionalPathEql(previous, selected)) {
            self.clearFileSearchDocumentAuthority();
        }
        self.selected_path = selected;

        var selected_cursor: ?usize = null;
        if (selected) |path| {
            selected_cursor = self.projectedCursorForPath(tree, path);
            if (selected_cursor == null and (reveal_preferred or retained == null)) {
                if (tree.nodeIndexForPath(path, self.file_visibility)) |node_index| {
                    if (tree.revealNodeFor(node_index, self.file_visibility) != null) {
                        selected_cursor = self.tree_projection.visibleIndexForTarget(
                            tree,
                            .{ .manifest_node = node_index },
                        );
                    }
                }
            }
        }
        self.viewer.tree_cursor = if (cursor_identity) |identity|
            self.tree_projection.cursorForIdentity(tree, self.file_visibility, identity)
        else
            selected_cursor orelse 0;
        if (selected == null) {
            self.viewer.tree_vertical_scroll = 0;
            self.reconcileNoSourceFocus();
        }
        if (self.file_search.mode) {
            self.refreshFileSearch();
        }
        self.clampScroll(body_height);
        return !optionalPathEql(previous, self.selected_path);
    }

    fn projectedCursorForPath(
        self: *const RepositoryPageState,
        tree: *const repository_tree.Tree,
        path: []const u8,
    ) ?usize {
        const node_index = tree.nodeIndexForPath(path, self.file_visibility) orelse return null;
        return self.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = node_index });
    }

    fn toggleChangedFilter(self: *RepositoryPageState, allocator: std.mem.Allocator, body_height: u16) void {
        switch (self.file_visibility) {
            .all => {
                const anchor = if (self.selected_path) |path|
                    allocator.dupe(u8, path) catch {
                        self.status.set("Could not preserve All selection", .{});
                        return;
                    }
                else
                    null;
                if (self.all_selection_anchor) |previous| allocator.free(previous);
                self.all_selection_anchor = anchor;
                self.file_visibility = .changed;
                _ = self.rebuildTreeProjection(self.selected_path, true, body_height);
            },
            .changed => {
                const anchor = self.all_selection_anchor;
                const preferred = if (anchor) |path| blk: {
                    const tree = if (self.bundle) |*bundle| &bundle.tree else break :blk self.selected_path;
                    break :blk tree.filePath(path, .all) orelse self.selected_path;
                } else self.selected_path;
                self.file_visibility = .all;
                _ = self.rebuildTreeProjection(preferred, true, body_height);
                if (anchor) |owned| allocator.free(owned);
                self.all_selection_anchor = null;
            },
        }
    }

    fn acceptFailure(self: *RepositoryPageState, message: []const u8) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("{s}", .{message});
    }

    fn reconcileLiveSelectionForMessage(
        self: *RepositoryPageState,
        msg: Msg,
        body_size: chasen.Size,
    ) void {
        const keep = switch (self.selection_owner) {
            .none => true,
            .source_header => switch (msg) {
                .mouse_owner_drag,
                .mouse_owner_release,
                .cancel_mouse_owner,
                .selection_action,
                .selection_owned_noop,
                => true,
                else => false,
            },
            .source => |live| switch (live.origin) {
                .mouse => switch (msg) {
                    .mouse_owner_drag,
                    .mouse_owner_release,
                    .mouse_source_auto_scroll_step,
                    .cancel_mouse_owner,
                    .selection_action,
                    .selection_owned_noop,
                    => true,
                    else => false,
                },
                .keyboard_line => switch (msg) {
                    .keyboard_line_selection_move,
                    .selection_action,
                    .selection_action_unavailable,
                    .selection_owned_noop,
                    .scroll_left,
                    .scroll_right,
                    .toggle_tree_visibility,
                    .decrease_tree_width,
                    .increase_tree_width,
                    .toggle_line_numbers,
                    .enter_source_search,
                    .cancel_source_search,
                    .clear_source_search,
                    .source_search_backspace,
                    .source_search_move_left,
                    .source_search_move_right,
                    .source_search_insert,
                    .source_search_paste,
                    .submit_source_search,
                    .next_source_match,
                    .previous_source_match,
                    .enter_file_search,
                    .cancel_file_search,
                    .submit_file_search,
                    .file_search_previous,
                    .file_search_next,
                    .file_search_backspace,
                    .file_search_insert,
                    .file_search_paste,
                    .mouse_source_press,
                    .mouse_source_header_press,
                    .mouse_source_wheel_up,
                    .mouse_source_wheel_down,
                    .cancel_mouse_owner,
                    => true,
                    else => false,
                },
            },
        };
        if (!keep) self.clearLiveSelectionPreservingViewport(body_size);
    }

    pub fn applyNavigation(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        msg: Msg,
        body_size: chasen.Size,
    ) RepositoryUpdate {
        var result: RepositoryUpdate = .{};
        var file_search_submitted = false;
        // A contextual destination is subordinate to the user's next
        // destination/navigation command. Dismiss it before that command can
        // mutate retained browser state. Pure presentation/cancel commands do
        // not retarget the browser and therefore retain the owner.
        if (navigationDismissesIncoming(msg)) self.dismissIncoming(allocator);
        self.reconcileLiveSelectionForMessage(msg, body_size);
        const keyboard_search_cursor = if (switch (msg) {
            .submit_source_search, .next_source_match, .previous_source_match => true,
            else => false,
        }) if (self.selection_owner.activeKeyboardLineSelection()) |live|
            live.focus.line_index
        else
            null else null;
        const previous = self.selected_path;
        const layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        const body_height = layout.treeRows(body_size.height);
        const source = self.currentSource();
        const source_projection = self.selectionActionProjection();
        const source_geometry = if (source) |document|
            repository_source_geometry.SourceGeometry.init(.{ .width = layout.source_width, .height = body_size.height }, document, self.viewer.line_numbers)
        else
            null;
        switch (msg) {
            .move_up => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.moveSourceProjected(&self.viewer, document, -1, source_geometry.?, source_projection),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(-1, body_height),
            },
            .move_down => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.moveSourceProjected(&self.viewer, document, 1, source_geometry.?, source_projection),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(1, body_height),
            },
            .wheel_up => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
                self.moveCursor(-1, body_height);
            },
            .wheel_down => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
                self.moveCursor(1, body_height);
            },
            .page_up => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.pageSourceProjected(&self.viewer, document, -1, source_geometry.?, source_projection),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(-@as(isize, @intCast(@max(body_height -| 1, 1))), body_height),
            },
            .page_down => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.pageSourceProjected(&self.viewer, document, 1, source_geometry.?, source_projection),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(@intCast(@max(body_height -| 1, 1)), body_height),
            },
            .toggle_directory => if (!self.viewer.tree_hidden) self.toggleCursor(body_height),
            .scroll_left => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.scrollSourceHorizontal(&self.viewer, document, -8, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) {
                    self.viewer.tree_horizontal_scroll -|= 4;
                },
            },
            .scroll_right => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.scrollSourceHorizontal(&self.viewer, document, 8, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) {
                    self.viewer.tree_horizontal_scroll = @min(self.viewer.tree_horizontal_scroll +| 4, manifest.max_path_bytes * 4);
                },
            },
            .mouse_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, false);
            },
            .mouse_toggle_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, true);
            },
            .mouse_source_header_press => |point| self.pressSourceHeader(point, body_size),
            .mouse_source_press => |point| self.pressSourceSelection(point, body_size),
            .mouse_owner_drag => |point| self.dragMouseOwner(point, body_size),
            .mouse_owner_release => |point| result.command = self.releaseMouseOwner(allocator, point, body_size),
            .mouse_source_auto_scroll_step => |step| result.auto_scroll = self.autoScrollSourceSelection(step, body_size),
            .cancel_mouse_owner => self.cancelMouseOwner(),
            .selection_action => |action| result.command = self.applySelectionAction(allocator, action, body_size),
            .selection_owned_noop => {},
            .selection_action_unavailable => self.status.set("Ask is not available for this selection", .{}),
            .begin_keyboard_line_selection => self.beginKeyboardLineSelection(body_size),
            .keyboard_line_selection_move => |direction| self.moveKeyboardLineSelection(allocator, direction, body_size),
            .mouse_source_wheel_up => if (source) |document| {
                self.viewer.focus = .source;
                if (self.activeKeyboardLineSelection())
                    repository_navigation.scrollSourceViewportProjected(&self.viewer, document, -1, source_geometry.?, source_projection)
                else
                    repository_navigation.wheelSourceProjected(&self.viewer, document, -1, source_geometry.?, source_projection);
            },
            .mouse_source_wheel_down => if (source) |document| {
                self.viewer.focus = .source;
                if (self.activeKeyboardLineSelection())
                    repository_navigation.scrollSourceViewportProjected(&self.viewer, document, 1, source_geometry.?, source_projection)
                else
                    repository_navigation.wheelSourceProjected(&self.viewer, document, 1, source_geometry.?, source_projection);
            },
            .focus_tree => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
            },
            .focus_source => if (source != null) {
                self.viewer.focus = .source;
            },
            .toggle_focus => if (source != null and !self.viewer.tree_hidden) {
                self.viewer.focus = if (self.viewer.focus == .tree) .source else .tree;
            },
            .toggle_tree_visibility => self.toggleTreeVisibility(body_size),
            .decrease_tree_width => self.adjustTreeWidth(.shrink, body_size),
            .increase_tree_width => self.adjustTreeWidth(.grow, body_size),
            .tree_first => if (!self.viewer.tree_hidden) self.selectTreeEdge(false, body_height),
            .tree_last => if (!self.viewer.tree_hidden) self.selectTreeEdge(true, body_height),
            .source_first => if (source) |document| repository_navigation.firstSourceProjected(&self.viewer, document, source_geometry.?, source_projection),
            .source_last => if (source) |document| repository_navigation.lastSourceProjected(&self.viewer, document, source_geometry.?, source_projection),
            .toggle_changed_filter => self.toggleChangedFilter(allocator, body_height),
            .toggle_line_numbers => {
                self.viewer.line_numbers = !self.viewer.line_numbers;
                if (source) |document| repository_navigation.clampSourceProjected(
                    &self.viewer,
                    document,
                    self.sourceGeometry(body_size, document),
                    source_projection,
                );
            },
            .enter_source_search => if (source != null) {
                self.source_search.mode = true;
                self.source_search.input = self.source_search.query;
                self.viewer.focus = .source;
            },
            .cancel_source_search => {
                self.source_search.mode = false;
                self.source_search.input = .{};
            },
            .submit_source_search => if (source) |document| {
                self.source_search.mode = false;
                self.source_search.query = self.source_search.input;
                self.source_search.match = document.findNext(self.source_search.query.slice(), null);
                if (self.source_search.match) |match| repository_navigation.revealMatchProjected(&self.viewer, document, match, source_geometry.?, source_projection) else self.status.set("No source match", .{});
            },
            .clear_source_search => self.source_search.clear(),
            .next_source_match => if (source) |document| {
                self.source_search.match = document.findNext(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatchProjected(&self.viewer, document, match, source_geometry.?, source_projection);
            },
            .previous_source_match => if (source) |document| {
                self.source_search.match = document.findPrevious(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatchProjected(&self.viewer, document, match, source_geometry.?, source_projection);
            },
            .source_search_backspace => self.source_search.input.backspace(),
            .source_search_move_left => self.source_search.input.moveLeft(),
            .source_search_move_right => self.source_search.input.moveRight(),
            .source_search_insert => |codepoint| self.source_search.input.insert(codepoint) catch self.status.set("Source search is too long", .{}),
            .source_search_paste => |text| self.source_search.input.insertSlice(text) catch self.status.set("Source search is too long", .{}),
            .enter_file_search => self.enterFileSearch(),
            .cancel_file_search => self.cancelFileSearch(body_size),
            .submit_file_search => file_search_submitted = self.submitFileSearch(body_size),
            .file_search_previous => self.file_search.move(-1),
            .file_search_next => self.file_search.move(1),
            .file_search_backspace => {
                self.file_search.input.backspace();
                self.refreshFileSearch();
            },
            .file_search_insert => |codepoint| {
                self.file_search.input.insert(codepoint) catch {
                    self.status.set("File search is too long", .{});
                    return result;
                };
                self.refreshFileSearch();
            },
            .file_search_paste => |text| {
                self.file_search.input.insertSlice(text) catch {
                    self.status.set("File search is too long", .{});
                    return result;
                };
                self.refreshFileSearch();
            },
            .manifest_finished, .branch_finished, .path_history_finished, .document_finished, .syntax_finished, .change_map_finished => unreachable,
        }
        if (!optionalPathEql(previous, self.selected_path)) {
            self.invalidateSelectedDocument(allocator);
            self.path_history.invalidate(allocator, self.selected_path != null);
            result.selected_path_changed = true;
        }
        if (file_search_submitted) self.commitFileSearchSourceFocus();
        if (keyboard_search_cursor) |cursor| if (self.viewer.source_cursor != cursor) {
            const document = self.currentSource();
            const viewport_anchor = if (document) |value| self.captureSourceViewportAnchor(value) else null;
            self.clearLiveSelection();
            if (document) |value| if (viewport_anchor) |anchor| {
                const geometry = self.sourceGeometry(body_size, value);
                self.restoreSourceViewportAnchor(anchor, value, geometry.visible_source_rows);
            };
        };
        return result;
    }

    fn invalidateSelectedDocument(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.clearFileSearchDocumentAuthority();
        self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        self.clearCompletedSelection(allocator);
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_document_revalidation = self.selected_path != null;
        if (self.displayed_document) |*document| document.deinit(allocator);
        self.displayed_document = null;
        self.viewer.resetSource();
        self.source_search.clear();
    }

    /// Separates scheduling intent from the authority of retained visible
    /// bytes. Every live source range borrows that authority, so commit its
    /// release before changing the authority at this shared boundary. A
    /// terminal request failure may consume retry intent, but it must never
    /// promote the last-good document back to accepted authority.
    fn invalidateDisplayedDocumentAuthority(self: *RepositoryPageState) void {
        const viewport_anchor = if (self.activeKeyboardLineSelection())
            if (self.currentSource()) |document| self.captureSourceViewportAnchor(document) else null
        else
            null;
        if (self.activeBorrowedSourceRange()) self.clearLiveSelection();
        std.debug.assert(!self.activeBorrowedSourceRange());
        if (self.displayed_document) |*document| {
            document.authority = .revalidation_required;
        }
        if (viewport_anchor) |anchor| if (self.currentSource()) |document| {
            // This page-level authority boundary has no frame geometry. Match
            // document replacement by preserving the semantic top without
            // inventing a terminal height; the coordinator clamps next frame.
            self.restoreSourceViewportAnchor(anchor, document, 0);
        };
    }

    fn requireDocumentRevalidation(self: *RepositoryPageState) void {
        self.invalidateDisplayedDocumentAuthority();
        self.needs_document_revalidation = self.selected_path != null;
    }

    fn currentSource(self: *const RepositoryPageState) ?*const source_document.Document {
        const displayed = if (self.displayed_document) |*document| document else return null;
        const selected = self.selected_path orelse return null;
        if (displayed.manifest_revision != self.manifest_revision or !std.mem.eql(u8, displayed.path, selected)) return null;
        return switch (displayed.value) {
            .source => |*source| source,
            .inert => null,
        };
    }

    /// Returns a displayed source only when it is also the current accepted
    /// Repository authority. `currentSource()` alone deliberately exposes a
    /// retained last-good document during reload/reactivation; consumers which
    /// commit a new interaction to source focus must not treat that visible
    /// fallback as a validated destination.
    fn acceptedCurrentSourceForSelection(self: *const RepositoryPageState) ?*const source_document.Document {
        if (!self.active or
            self.activation_id == 0 or
            self.root_identity == null or
            self.freshness != .fresh or
            self.needs_revalidation or
            self.needs_document_revalidation or
            self.pending_generation != null or
            self.pending_document_generation != null)
        {
            return null;
        }
        const displayed = if (self.displayed_document) |*document| document else return null;
        if (displayed.authority != .accepted) return null;
        return self.currentSource();
    }

    /// Keep raw page focus valid even when a selected document becomes an
    /// inert checkpoint. Input derives an effective focus too, but lifecycle
    /// reconciliation must never leave an invisible tree as the stored owner.
    fn reconcileNoSourceFocus(self: *RepositoryPageState) void {
        if (self.currentSource() != null) return;
        self.viewer.focus = if (self.viewer.tree_hidden) .source else .tree;
    }

    pub fn inputContext(
        self: *const RepositoryPageState,
        effective_keymap: keymap.Effective,
    ) repository_input.Context {
        const source_available = self.currentSource() != null;
        return .{
            .focus = if (self.viewer.tree_hidden) .source else if (source_available) self.viewer.focus else .tree,
            .source_available = source_available,
            .tree_hidden = self.viewer.tree_hidden,
            .source_search_mode = self.source_search.mode,
            .file_search_mode = self.file_search.mode,
            .selection_owner = switch (self.selection_owner) {
                .none => .none,
                .source_header => .header,
                .source => |selection| if (selection.origin == .keyboard_line) .keyboard_line else .mouse,
            },
            .retained_selection_action_available = self.retainedSourceSelection() != null,
            .source_query_len = self.source_search.query.len,
            .keymap = effective_keymap,
        };
    }

    fn selectTreeEdge(self: *RepositoryPageState, last: bool, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        self.viewer.tree_cursor = 0;
        if (last) {
            var index = tree.visible_len;
            while (index > 0) {
                index -= 1;
                const node_index = tree.visible[index];
                if (tree.nodes[node_index].kind == .file) {
                    self.viewer.tree_cursor = self.tree_projection.visibleIndexForTarget(
                        tree,
                        .{ .manifest_node = node_index },
                    ) orelse 0;
                    break;
                }
            }
        } else {
            for (tree.visibleNodes()) |node_index| if (tree.nodes[node_index].kind == .file) {
                self.viewer.tree_cursor = self.tree_projection.visibleIndexForTarget(
                    tree,
                    .{ .manifest_node = node_index },
                ) orelse 0;
                break;
            };
        }
        self.viewer.focus = .tree;
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn adjustTreeWidth(
        self: *RepositoryPageState,
        direction: repository_layout.WidthDirection,
        body_size: chasen.Size,
    ) void {
        self.viewer.tree_width = repository_layout.adjustedTreeWidth(
            body_size.width,
            self.viewer.tree_width,
            direction,
        );
        self.clampForBodySize(body_size);
    }

    fn preferredTreeHidden(self: *const RepositoryPageState) bool {
        return self.viewer.tree_hidden or (self.file_search.mode and self.file_search.restore_tree_hidden);
    }

    fn toggleTreeVisibility(self: *RepositoryPageState, body_size: chasen.Size) void {
        if (self.viewer.tree_hidden) {
            self.viewer.tree_hidden = false;
            self.viewer.focus = if (self.viewer.tree_return_focus == .source and self.currentSource() == null)
                .tree
            else
                self.viewer.tree_return_focus;
        } else {
            self.viewer.tree_return_focus = self.viewer.focus;
            self.viewer.tree_hidden = true;
            self.viewer.focus = .source;
        }
        self.clampForBodySize(body_size);
    }

    fn enterFileSearch(self: *RepositoryPageState) void {
        self.file_search = .{
            .mode = true,
            .return_focus = self.viewer.focus,
            .restore_tree_hidden = self.viewer.tree_hidden,
        };
        // Search candidates are tree destinations. Revealing the tree for the
        // prompt avoids displaying a focus target in an invisible pane; cancel
        // still owns enough state to restore the user's hidden preference.
        self.viewer.tree_hidden = false;
        self.viewer.focus = .tree;
        self.refreshFileSearch();
    }

    /// Publish candidates only when every basis required by the active lens
    /// is authoritative. In Changed mode an accepted manifest alone is not
    /// enough: missing status is unavailable, not an authoritative empty set.
    fn refreshFileSearch(self: *RepositoryPageState) void {
        if (!self.file_search.mode) return;
        const bundle = if (self.bundle) |*bundle| bundle else {
            self.file_search.resetResults();
            return;
        };
        if (self.file_visibility == .changed and !bundle.status_available) {
            self.file_search.resetResults();
            return;
        }
        repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
    }

    fn cancelFileSearch(self: *RepositoryPageState, body_size: chasen.Size) void {
        const return_focus = self.file_search.return_focus;
        const restore_tree_hidden = self.file_search.restore_tree_hidden;
        self.file_search.close();
        self.viewer.tree_hidden = restore_tree_hidden;
        self.viewer.focus = if (restore_tree_hidden)
            .source
        else if (return_focus == .source and self.currentSource() == null)
            .tree
        else
            return_focus;
        self.clampForBodySize(body_size);
    }

    fn submitFileSearch(self: *RepositoryPageState, body_size: chasen.Size) bool {
        if (!self.file_search.projection_available) return false;
        const node_index = self.file_search.selectedNode() orelse {
            self.file_search.no_match = true;
            return false;
        };
        const tree = if (self.bundle) |*bundle| &bundle.tree else return false;
        const visible = self.tree_projection.revealManifestNode(tree, self.file_visibility, node_index) orelse return false;
        const selected = tree.nodes[node_index].path;
        // A new successful submit always supersedes an older pane-focus intent.
        // Preserve a typed pending request only for the same-path direct-bind
        // case; changing paths invalidates that request authority immediately.
        self.file_search_source_focus.clear();
        if (!optionalPathEql(self.selected_path, selected)) {
            self.clearPendingDocumentAuthority();
        }
        self.viewer.tree_cursor = visible;
        self.viewer.tree_hidden = false;
        self.viewer.focus = .tree;
        self.selected_path = selected;
        self.file_search.close();
        self.clampForBodySize(body_size);
        return true;
    }

    /// Classify a successful exact candidate after generic selection
    /// invalidation has committed the new path. Until one of these authority
    /// cases succeeds, tree focus is the bounded and truthful terminal.
    fn commitFileSearchSourceFocus(self: *RepositoryPageState) void {
        if (!self.active) return;
        const basis = self.currentFileSearchFocusBasis() orelse return;
        if (self.acceptedCurrentSourceForSelection() != null) {
            self.file_search_source_focus.clear();
            self.viewer.focus = .source;
            return;
        }

        if (self.pending_document_generation) |generation| {
            if (self.pending_document_request) |pending| {
                if (self.file_search_source_focus.bindExisting(basis, generation, pending)) return;
            }
        }

        if (self.wantsDocumentRequest()) {
            self.file_search_source_focus.awaitDocumentRequest(basis);
        } else {
            self.file_search_source_focus.clear();
        }
    }

    fn moveCursor(self: *RepositoryPageState, delta: isize, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const visible_len = self.tree_projection.visibleLen(tree);
        if (delta < 0) self.viewer.tree_cursor -|= @intCast(-delta) else self.viewer.tree_cursor = @min(self.viewer.tree_cursor +| @as(usize, @intCast(delta)), visible_len - 1);
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn setCursor(self: *RepositoryPageState, body_row: usize, body_height: u16, toggle: bool) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const index = self.viewer.tree_vertical_scroll + body_row;
        const target = self.tree_projection.targetAt(tree, index) orelse return;
        self.viewer.tree_cursor = index;
        if (toggle and switch (target) {
            .repo_root => true,
            .manifest_node => |node_index| tree.nodes[node_index].kind == .directory,
        }) self.toggleCursor(body_height) else self.selectCursor();
    }

    fn toggleCursor(self: *RepositoryPageState, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const target = self.tree_projection.targetAt(tree, self.viewer.tree_cursor) orelse return;
        if (self.tree_projection.activateTarget(tree, self.file_visibility, target)) {
            self.viewer.tree_cursor = @min(
                self.viewer.tree_cursor,
                self.tree_projection.visibleLen(tree) - 1,
            );
            self.clampScroll(body_height);
        } else self.selectCursor();
    }

    fn selectCursor(self: *RepositoryPageState) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const target = self.tree_projection.targetAt(tree, self.viewer.tree_cursor) orelse return;
        switch (target) {
            .repo_root => {},
            .manifest_node => |node_index| {
                const node = tree.nodes[node_index];
                if (node.kind == .file) {
                    if (!optionalPathEql(self.selected_path, node.path)) {
                        self.clearFileSearchDocumentAuthority();
                    }
                    self.selected_path = node.path;
                }
            },
        }
    }

    pub fn clampScroll(self: *RepositoryPageState, body_height: u16) void {
        const visible_len = if (self.bundle) |*bundle| self.tree_projection.visibleLen(&bundle.tree) else 0;
        if (visible_len == 0) {
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            return;
        }
        self.viewer.tree_cursor = @min(self.viewer.tree_cursor, visible_len - 1);
        const rows: usize = @max(@as(usize, body_height), 1);
        if (self.viewer.tree_cursor < self.viewer.tree_vertical_scroll) self.viewer.tree_vertical_scroll = self.viewer.tree_cursor;
        if (self.viewer.tree_cursor >= self.viewer.tree_vertical_scroll + rows) self.viewer.tree_vertical_scroll = self.viewer.tree_cursor - rows + 1;
        self.viewer.tree_vertical_scroll = @min(self.viewer.tree_vertical_scroll, visible_len -| rows);
    }

    fn placeIncomingTreeForBodySize(self: *RepositoryPageState, body_size: chasen.Size) void {
        const layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        self.viewer.tree_vertical_scroll = 0;
        const rows = layout.treeRows(body_size.height);
        if (rows == 0) return;
        self.clampScroll(rows);
    }

    pub fn clampForBodySize(self: *RepositoryPageState, body_size: chasen.Size) void {
        const layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        self.clampScroll(layout.treeRows(body_size.height));
        if (self.currentSource()) |document| {
            repository_navigation.clampSourceProjected(
                &self.viewer,
                document,
                self.sourceGeometry(body_size, document),
                self.selectionActionProjection(),
            );
        }
    }

    /// Any Repository gesture which owns pane-external drag/release routing
    /// and excludes replacement press/wheel events.
    pub fn activeMouseOwner(self: *const RepositoryPageState) bool {
        return self.selection_owner.activeMouseOwner();
    }

    /// Only a mouse-origin source range. Keyboard ranges never acquire pointer
    /// continuation, auto-scroll, or page-transition blocker authority.
    pub fn activeMouseSourceRange(self: *const RepositoryPageState) bool {
        return self.selection_owner.activeMouseSourceRange();
    }

    pub fn activeKeyboardLineSelection(self: *const RepositoryPageState) bool {
        return self.selection_owner.activeKeyboardLineSelection() != null;
    }

    pub fn activeBorrowedSourceRange(self: *const RepositoryPageState) bool {
        return self.selection_owner.activeBorrowedSourceRange();
    }

    /// Body-relative source viewport used only by the root pointer policy.
    /// Source identity and token stay page-private and are revalidated again
    /// when the semantic step is consumed.
    pub fn sourceAutoScrollViewport(
        self: *const RepositoryPageState,
        body_size: chasen.Size,
    ) ?drag_auto_scroll.Viewport {
        const live = self.selection_owner.activeMouseSource() orelse return null;
        const token = self.currentContentToken() orelse return null;
        if (!live.token.eql(token)) return null;
        const document = self.currentSource() orelse return null;
        const layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        if (layout.source_width == 0) return null;
        const geometry = self.sourceGeometry(body_size, document);
        if (geometry.visible_source_rows < 2) return null;
        return .{
            .first_col = layout.source_col,
            .last_col = layout.source_col + layout.source_width - 1,
            .first_row = geometry.body_first_row,
            .last_row = geometry.body_first_row + geometry.visible_source_rows - 1,
        };
    }

    /// Returns only a live selection already proved against the current
    /// displayed source identity. The borrowed projection is valid for the
    /// caller's synchronous use of this immutable state snapshot.
    pub fn liveSourceSelection(self: *const RepositoryPageState) ?repository_selection.DragSelection {
        const live = self.selection_owner.activeSource() orelse return null;
        const token = self.currentContentToken() orelse return null;
        return if (live.token.eql(token)) live else null;
    }

    /// Header-path gestures own pointer capture but never accepted source
    /// bytes. A different-page request may therefore cancel this owner and
    /// continue instead of using the source-range transition blocker.
    pub fn cancelSourceHeaderOwner(self: *RepositoryPageState) bool {
        if (self.selection_owner.activeSourceHeader() == null) return false;
        self.cancelMouseOwner();
        return true;
    }

    pub fn sourceHeaderSelected(self: *const RepositoryPageState) bool {
        const selection = self.selection_owner.activeSourceHeader() orelse return false;
        const current = self.currentSourceHeaderIdentity() orelse return false;
        return selection.identity.eql(current);
    }

    /// Projects only header facts proved for the selected manifest path.
    /// Rendering and hit testing share the same authority-gated contract.
    pub fn sourceHeaderPresentation(
        self: *const RepositoryPageState,
    ) ?repository_source_header.Presentation {
        const selected_path = self.selected_path orelse return null;
        return projectSourceHeaderPresentation(self, selected_path);
    }

    /// End only pointer-origin ownership. Layout-only transitions call this so
    /// a semantic keyboard range can survive geometry changes.
    pub fn cancelMouseOwner(self: *RepositoryPageState) void {
        if (self.selection_owner.activeMouseOwner()) self.selection_owner = .none;
    }

    /// End every borrowed live range before document or repository authority
    /// changes. Owned completed candidates have an independent lifecycle.
    pub fn clearLiveSelection(self: *RepositoryPageState) void {
        self.selection_owner = .none;
    }

    /// End a semantic keyboard projection without retargeting the visible
    /// source top. Pointer owners do not own a presentation projection, so
    /// their cancellation remains allocation-free and mapping-neutral.
    pub fn clearLiveSelectionPreservingViewport(
        self: *RepositoryPageState,
        body_size: chasen.Size,
    ) void {
        const document = self.currentSource();
        const viewport_anchor = if (self.activeKeyboardLineSelection())
            if (document) |value| self.captureSourceViewportAnchor(value) else null
        else
            null;
        self.clearLiveSelection();
        if (viewport_anchor) |anchor| if (document) |value| {
            const geometry = self.sourceGeometry(body_size, value);
            self.restoreSourceViewportAnchor(anchor, value, geometry.visible_source_rows);
        };
    }

    fn clearCompletedSelection(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        if (self.completed_selection) |*completed| completed.deinit(allocator);
        self.completed_selection = null;
    }

    /// The one authority predicate consumed by Repository render, hit-test,
    /// keyboard/mouse dispatch, and virtual-row projection.
    pub fn retainedSourceSelection(
        self: *const RepositoryPageState,
    ) ?*const repository_selection.CompletedSelection {
        const completed = if (self.completed_selection) |*value| value else return null;
        const document = self.currentSource() orelse return null;
        const token = self.currentContentToken() orelse return null;
        return if (completed.isAdmitted(document, token)) completed else null;
    }

    pub fn sourceSelectionPresentation(self: *const RepositoryPageState) ?SourceSelectionPresentation {
        if (self.selection_owner.activeKeyboardLineSelection()) |live| {
            const document = self.currentSource() orelse return null;
            const token = self.currentContentToken() orelse return null;
            const range = live.range();
            const content_lines = document.contentLineCount();
            if (!live.token.eql(token) or content_lines == 0 or
                range.start.line_index >= content_lines or range.end.line_index >= content_lines)
            {
                return null;
            }
            return .{ .range = range, .line_count = live.lineCount(), .owner = .active_keyboard };
        }
        const completed = self.retainedSourceSelection() orelse return null;
        return .{ .range = completed.range, .line_count = completed.line_count, .owner = .completed };
    }

    pub fn selectionActionProjection(self: *const RepositoryPageState) ?selection_action.Projection {
        const presentation = self.sourceSelectionPresentation() orelse return null;
        const document = self.currentSource() orelse return null;
        return selection_action.Projection.init(document.rowCount(), presentation.range.end.line_index);
    }

    fn sourceProjectionBasis(
        self: *const RepositoryPageState,
        document: *const source_document.Document,
        projection: ?selection_action.Projection,
    ) selection_action.ProjectionBasis {
        return .{
            .layout_revision = self.source_revision,
            .source_rows = document.rowCount(),
            .action_insertion_offset = if (projection) |value| value.insertionOffset() else null,
        };
    }

    fn captureSourceViewportAnchor(
        self: *const RepositoryPageState,
        document: *const source_document.Document,
    ) SelectionViewportAnchor {
        const projection = self.selectionActionProjection();
        const position = selection_action.captureAnchorPosition(
            document.rowCount(),
            projection,
            self.viewer.source_vertical_scroll,
        );
        return .{
            .semantic_source = position.source_offset_fallback,
            .source_offset_fallback = position.source_offset_fallback,
            .signed_screen_delta = position.signed_screen_delta,
            .raw_presentation_scroll = self.viewer.source_vertical_scroll,
            .basis = self.sourceProjectionBasis(document, projection),
        };
    }

    fn restoreSourceViewportAnchor(
        self: *RepositoryPageState,
        anchor: SelectionViewportAnchor,
        document: *const source_document.Document,
        visible_rows: usize,
    ) void {
        const projection = self.selectionActionProjection();
        self.viewer.source_vertical_scroll = selection_action.restoreViewportAnchor(
            anchor,
            self.sourceProjectionBasis(document, projection),
            projection,
            @min(anchor.semantic_source, document.rowCount() - 1),
            visible_rows,
        );
    }

    pub fn captureSelectionViewportAnchor(
        self: *const RepositoryPageState,
    ) ?SelectionViewportAnchor {
        if (self.sourceSelectionPresentation() == null) return null;
        const document = self.currentSource() orelse return null;
        return self.captureSourceViewportAnchor(document);
    }

    pub fn restoreSelectionViewportAnchor(
        self: *RepositoryPageState,
        anchor: SelectionViewportAnchor,
        body_size: chasen.Size,
    ) void {
        // First reconcile unrelated tree/cursor/horizontal bounds, then make
        // the semantic source anchor the final vertical authority.
        self.clampForBodySize(body_size);
        const document = self.currentSource() orelse return;
        const geometry = self.sourceGeometry(body_size, document);
        self.restoreSourceViewportAnchor(anchor, document, geometry.visible_source_rows);
    }

    fn clearCompletedSelectionPreservingViewport(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
    ) void {
        const document = self.currentSource();
        const anchor = if (document) |value| self.captureSourceViewportAnchor(value) else null;
        self.clearCompletedSelection(allocator);
        if (document) |value| if (anchor) |captured| {
            const geometry = self.sourceGeometry(body_size, value);
            self.restoreSourceViewportAnchor(captured, value, geometry.visible_source_rows);
        };
    }

    fn clearLiveAndCompletedSelectionPreservingViewport(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
    ) void {
        const document = self.currentSource();
        const anchor = if (document) |value| self.captureSourceViewportAnchor(value) else null;
        self.clearLiveSelection();
        self.clearCompletedSelection(allocator);
        if (document) |value| if (anchor) |captured| {
            const geometry = self.sourceGeometry(body_size, value);
            self.restoreSourceViewportAnchor(captured, value, geometry.visible_source_rows);
        };
    }

    fn beginKeyboardLineSelection(self: *RepositoryPageState, body_size: chasen.Size) void {
        if (self.selection_owner != .none or self.source_search.mode or self.file_search.mode) return;
        if (!self.viewer.tree_hidden and self.viewer.focus != .source) {
            self.status.set("Keyboard selection requires source focus", .{});
            return;
        }
        const document = self.acceptedCurrentSourceForSelection() orelse {
            self.status.set("Source selection is not available", .{});
            return;
        };
        const content_lines = document.contentLineCount();
        if (content_lines == 0) {
            self.status.set("No source line is available for selection", .{});
            return;
        }
        const token = self.currentContentToken() orelse {
            self.status.set("Source selection has no current basis", .{});
            return;
        };

        const viewport_anchor = self.captureSourceViewportAnchor(document);
        const line_index = @min(self.viewer.source_cursor, content_lines - 1);
        self.selection_owner = .{ .source = repository_selection.DragSelection.initKeyboardLine(token, line_index) };
        self.viewer.focus = .source;
        self.viewer.source_cursor = line_index;
        const geometry = self.sourceGeometry(body_size, document);
        self.restoreSourceViewportAnchor(viewport_anchor, document, geometry.visible_source_rows);
        repository_navigation.moveSourceProjected(
            &self.viewer,
            document,
            0,
            geometry,
            self.selectionActionProjection(),
        );
        self.revealKeyboardSelectionAction(document, geometry);
        self.status.clear();
    }

    fn moveKeyboardLineSelection(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        direction: app_direction.Vertical,
        body_size: chasen.Size,
    ) void {
        var live = self.selection_owner.activeKeyboardLineSelection() orelse return;
        const document = self.acceptedCurrentSourceForSelection() orelse {
            self.invalidateActiveKeyboardSelection(allocator, body_size, "Source selection is no longer available");
            return;
        };
        const token = self.currentContentToken() orelse {
            self.invalidateActiveKeyboardSelection(allocator, body_size, "Source selection has no current basis");
            return;
        };
        const content_lines = document.contentLineCount();
        if (!live.token.eql(token) or content_lines == 0 or
            live.anchor.line_index >= content_lines or live.focus.line_index >= content_lines)
        {
            self.invalidateActiveKeyboardSelection(allocator, body_size, "Source selection is no longer current");
            return;
        }

        const next_line = switch (direction) {
            .up => live.focus.line_index -| 1,
            .down => @min(live.focus.line_index +| 1, content_lines - 1),
        };
        if (next_line == live.focus.line_index) return;

        const viewport_anchor = self.captureSourceViewportAnchor(document);
        live.update(repository_selection.pointFromLine(next_line));
        self.selection_owner = .{ .source = live };
        self.viewer.focus = .source;
        self.viewer.source_cursor = next_line;
        const geometry = self.sourceGeometry(body_size, document);
        self.restoreSourceViewportAnchor(viewport_anchor, document, geometry.visible_source_rows);
        repository_navigation.moveSourceProjected(
            &self.viewer,
            document,
            0,
            geometry,
            self.selectionActionProjection(),
        );
        self.revealKeyboardSelectionAction(document, geometry);
        self.status.clear();
    }

    fn revealKeyboardSelectionAction(
        self: *RepositoryPageState,
        document: *const source_document.Document,
        geometry: repository_source_geometry.SourceGeometry,
    ) void {
        const live = self.selection_owner.activeKeyboardLineSelection() orelse return;
        if (live.focus.line_index != live.range().end.line_index) return;
        const projection = self.selectionActionProjection() orelse return;
        self.viewer.source_vertical_scroll = projection.reveal(
            self.viewer.source_vertical_scroll,
            geometry.visible_source_rows,
        );
        repository_navigation.clampSourceProjected(
            &self.viewer,
            document,
            geometry,
            projection,
        );
    }

    fn invalidateActiveKeyboardSelection(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
        message: []const u8,
    ) void {
        const document = self.currentSource();
        const viewport_anchor = if (document) |value| self.captureSourceViewportAnchor(value) else null;
        self.clearLiveSelection();
        if (self.completed_selection != null and self.retainedSourceSelection() == null) {
            self.clearCompletedSelection(allocator);
        }
        if (document) |value| if (viewport_anchor) |anchor| {
            const geometry = self.sourceGeometry(body_size, value);
            self.restoreSourceViewportAnchor(anchor, value, geometry.visible_source_rows);
        };
        self.status.set("{s}", .{message});
    }

    fn keyboardLineSelectionAdmitted(self: *const RepositoryPageState) bool {
        const live = self.selection_owner.activeKeyboardLineSelection() orelse return false;
        const document = self.acceptedCurrentSourceForSelection() orelse return false;
        const token = self.currentContentToken() orelse return false;
        const content_lines = document.contentLineCount();
        return live.mode == .line and live.token.eql(token) and content_lines > 0 and
            live.anchor.line_index < content_lines and live.focus.line_index < content_lines;
    }

    /// Reconcile only an already accepted selected-document result. At this
    /// point repo/root/path authority has been checked by `applyDocumentFinished`
    /// and a source result supplies the final fingerprint needed to compare the
    /// complete semantic token. Inert results cannot prove compatible source
    /// bytes and therefore remain fail-closed.
    fn reconcileCompletedSelectionForDocument(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        finished: *const repository_tasks.DocumentFinished,
    ) void {
        const completed = if (self.completed_selection) |*selection| selection else return;
        const fingerprint = switch (finished.value) {
            .source => |source| source.fingerprint,
            .inert => {
                self.clearCompletedSelection(allocator);
                return;
            },
        };
        const incoming = repository_selection.RepositoryContentToken{
            .repo_epoch = self.repo_epoch,
            .root_identity = finished.root_identity,
            .path = finished.path,
            .source_fingerprint = fingerprint,
        };
        if (!completed.token.view().eql(incoming)) self.clearCompletedSelection(allocator);
    }

    fn sourceGeometry(self: *const RepositoryPageState, body_size: chasen.Size, document: *const source_document.Document) repository_source_geometry.SourceGeometry {
        const layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        return .init(
            .{ .width = layout.source_width, .height = body_size.height },
            document,
            self.viewer.line_numbers,
        );
    }

    fn currentContentToken(self: *const RepositoryPageState) ?repository_selection.RepositoryContentToken {
        const displayed = if (self.displayed_document) |*document| document else return null;
        const source = self.currentSource() orelse return null;
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity orelse return null,
            .path = displayed.path,
            .source_fingerprint = source.fingerprint,
        };
    }

    /// Resolves the manifest-owned path identity independently from selected
    /// source content. This is what lets loading and inert files participate
    /// in header-path copy without pretending that source bytes are accepted.
    fn currentSourceHeaderIdentity(self: *const RepositoryPageState) ?repository_selection.SourceHeaderIdentity {
        if (!self.active or self.activation_id == 0) return null;
        const root_identity = self.root_identity orelse return null;
        const bundle = if (self.bundle) |*value| value else return null;
        const path = self.selected_path orelse return null;
        _ = bundle.tree.nodeIndexForPath(path, .all) orelse return null;
        return .{
            .repo_epoch = self.repo_epoch,
            .activation_id = self.activation_id,
            .root_identity = root_identity,
            .manifest_revision = self.manifest_revision,
            .path = path,
        };
    }

    fn sourceHeaderPathHit(
        self: *const RepositoryPageState,
        point: repository_layout.BodyPoint,
        body_size: chasen.Size,
    ) ?repository_selection.SourceHeaderIdentity {
        if (self.incomingUnavailable() != null or
            self.file_search.mode or
            point.row != repository_source_geometry.source_path_row)
        {
            return null;
        }
        switch (self.load_state) {
            .idle, .no_repository, .failed => return null,
            .loading => if (self.file_visibility == .all) return null,
            .empty, .loaded => {},
        }
        const page_layout = repository_layout.bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        if (page_layout.source_width == 0 or point.col >= page_layout.source_width) return null;
        const identity = self.currentSourceHeaderIdentity() orelse return null;
        const presentation = self.sourceHeaderPresentation() orelse return null;
        const target = repository_source_header.layout(page_layout.source_width, presentation).path_target orelse return null;
        if (!target.contains(point.col)) return null;
        return identity;
    }

    fn pressSourceHeader(self: *RepositoryPageState, point: repository_layout.BodyPoint, body_size: chasen.Size) void {
        const identity = self.sourceHeaderPathHit(point, body_size) orelse return;
        const document = self.currentSource();
        const viewport_anchor = if (self.activeKeyboardLineSelection())
            if (document) |value| self.captureSourceViewportAnchor(value) else null
        else
            null;
        if (document != null) self.viewer.focus = .source;
        self.selection_owner = .{ .source_header = .{ .identity = identity } };
        if (viewport_anchor) |anchor| if (document) |value| {
            const geometry = self.sourceGeometry(body_size, value);
            self.restoreSourceViewportAnchor(anchor, value, geometry.visible_source_rows);
        };
    }

    fn selectionActionHit(
        self: *const RepositoryPageState,
        point: repository_layout.BodyPoint,
        body_size: chasen.Size,
    ) ?SelectionActionHit {
        const document = self.currentSource() orelse return null;
        const projection = self.selectionActionProjection() orelse return null;
        const geometry = self.sourceGeometry(body_size, document);
        const location = geometry.locationAt(
            point.row,
            self.viewer.source_vertical_scroll,
            document,
            projection,
        ) orelse return null;
        const action_row = switch (location) {
            .source => return null,
            .action => |row| row,
        };
        const layout = selection_action.actionLayout(.{ .col = 0, .width = geometry.width });
        return if (layout.targetAt(point.col, action_row)) |action|
            .{ .target = action }
        else
            .inert;
    }

    fn dragMouseOwner(self: *RepositoryPageState, point: ?repository_layout.BodyPoint, body_size: chasen.Size) void {
        if (self.selection_owner.activeMouseSource() != null) self.dragSourceSelection(point, body_size);
        // A header gesture owns the pointer stream but has no moving endpoint:
        // both click and drag release copy the same whole path.
    }

    fn releaseMouseOwner(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        point: ?repository_layout.BodyPoint,
        body_size: chasen.Size,
    ) ?Command {
        if (self.selection_owner.activeMouseSource() != null) {
            return self.releaseSourceSelection(allocator, point, body_size);
        }
        if (self.selection_owner.activeSourceHeader() != null) return self.releaseSourceHeaderPath(allocator);
        return null;
    }

    fn releaseSourceHeaderPath(self: *RepositoryPageState, allocator: std.mem.Allocator) ?Command {
        const selection = self.selection_owner.activeSourceHeader() orelse return null;
        const current = self.currentSourceHeaderIdentity() orelse {
            self.cancelMouseOwner();
            return null;
        };
        if (!selection.identity.eql(current)) {
            self.cancelMouseOwner();
            return null;
        }
        const path = allocator.dupe(u8, current.path) catch {
            self.cancelMouseOwner();
            self.status.set("Could not prepare file path copy", .{});
            return null;
        };
        self.cancelMouseOwner();
        self.status.clear();
        return .{ .copy_source_header_path = path };
    }

    fn pointAtTextCell(
        document: *const source_document.Document,
        line_index: usize,
        horizontal_scroll: usize,
        viewport_cell: usize,
    ) ?repository_selection.Point {
        const line = document.lineBody(line_index) orelse return null;
        const projection = text_projection.Projection.init(line, .{ .tab_width = repository_tab_width }) catch return null;
        return switch (projection.hitViewportCell(horizontal_scroll, viewport_cell)) {
            .token => |token| repository_selection.pointFromToken(line_index, token),
            .boundary => |boundary| repository_selection.pointFromBoundary(line_index, boundary.byte_offset),
        };
    }

    fn pressSourceSelection(self: *RepositoryPageState, point: repository_layout.BodyPoint, body_size: chasen.Size) void {
        if (self.source_search.mode or self.file_search.mode) return;
        const document = self.acceptedCurrentSourceForSelection() orelse return;
        const geometry = self.sourceGeometry(body_size, document);
        const line_index = geometry.contentLineAtProjected(
            point.row,
            self.viewer.source_vertical_scroll,
            document,
            self.selectionActionProjection(),
        ) orelse return;
        const region = geometry.regionAt(point.col) orelse return;
        const token = self.currentContentToken() orelse return;
        const mode: repository_selection.Mode = switch (region) {
            .gutter, .line_number => .line,
            .text => .character,
            .separator => return,
        };
        const logical_point = switch (mode) {
            .line => repository_selection.pointFromLine(line_index),
            .character => pointAtTextCell(
                document,
                line_index,
                self.viewer.source_horizontal_scroll,
                @as(usize, point.col - geometry.text_col),
            ) orelse return,
        };
        const viewport_anchor = if (self.activeKeyboardLineSelection())
            self.captureSourceViewportAnchor(document)
        else
            null;
        self.viewer.focus = .source;
        self.viewer.source_cursor = line_index;
        self.selection_owner = .{ .source = repository_selection.DragSelection.initAtCell(
            token,
            mode,
            logical_point,
            .{ .col = point.col, .row = point.row },
        ) };
        if (viewport_anchor) |anchor| {
            self.restoreSourceViewportAnchor(anchor, document, geometry.visible_source_rows);
        }
    }

    fn dragSourceSelection(self: *RepositoryPageState, point: ?repository_layout.BodyPoint, body_size: chasen.Size) void {
        var live = self.selection_owner.activeMouseSource() orelse return;
        const local = point orelse return;
        const document = self.currentSource() orelse {
            self.cancelMouseOwner();
            return;
        };
        const current_token = self.currentContentToken() orelse {
            self.cancelMouseOwner();
            return;
        };
        if (!live.token.eql(current_token)) {
            self.cancelMouseOwner();
            return;
        }
        const geometry = self.sourceGeometry(body_size, document);
        const line_index = geometry.contentLineAtProjected(
            local.row,
            self.viewer.source_vertical_scroll,
            document,
            self.selectionActionProjection(),
        ) orelse return;
        const region = geometry.regionAt(local.col) orelse return;
        const logical_point: repository_selection.Point = switch (live.mode) {
            .line => repository_selection.pointFromLine(line_index),
            .character => switch (region) {
                .gutter, .line_number => repository_selection.pointFromBoundary(line_index, 0),
                .separator => return,
                .text => pointAtTextCell(
                    document,
                    line_index,
                    self.viewer.source_horizontal_scroll,
                    @as(usize, local.col - geometry.text_col),
                ) orelse return,
            },
        };
        self.viewer.source_cursor = line_index;
        live.updateAtCell(logical_point, .{ .col = local.col, .row = local.row });
        self.selection_owner = .{ .source = live };
    }

    fn autoScrollSourceSelection(
        self: *RepositoryPageState,
        step: drag_auto_scroll.Step,
        body_size: chasen.Size,
    ) drag_auto_scroll.StepOutcome {
        const live = self.selection_owner.activeMouseSource() orelse {
            self.cancelMouseOwner();
            return .stale_owner;
        };
        const document = self.currentSource() orelse {
            self.cancelMouseOwner();
            return .stale_owner;
        };
        const token = self.currentContentToken() orelse {
            self.cancelMouseOwner();
            return .stale_owner;
        };
        if (!live.token.eql(token)) {
            self.cancelMouseOwner();
            return .stale_owner;
        }

        const geometry = self.sourceGeometry(body_size, document);
        const old_scroll = self.viewer.source_vertical_scroll;
        repository_navigation.wheelSourceProjected(
            &self.viewer,
            document,
            if (step.direction == .up) -1 else 1,
            geometry,
            self.selectionActionProjection(),
        );
        if (self.viewer.source_vertical_scroll == old_scroll) return .content_edge;

        self.dragSourceSelection(.{
            .col = step.endpoint.col,
            .row = step.endpoint.row,
        }, body_size);
        if (self.selection_owner.activeMouseSource() == null) return .stale_owner;
        return .moved;
    }

    fn releaseSourceSelection(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        point: ?repository_layout.BodyPoint,
        body_size: chasen.Size,
    ) ?Command {
        if (!self.activeMouseSourceRange()) return null;
        self.dragSourceSelection(point, body_size);
        const live = self.selection_owner.activeMouseSource() orelse {
            // A defensive identity failure inside the final drag invalidates
            // the basis for both the gesture and any prior candidate.
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.status.set("Source selection is no longer current", .{});
            return null;
        };
        if (!live.moved) {
            // A click still updates focus/cursor at press time, but it is not a
            // replacement transaction for the prior release-frozen candidate.
            self.cancelMouseOwner();
            return null;
        }

        const document = self.currentSource() orelse {
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection is no longer available", .{});
            return null;
        };
        const current_token = self.currentContentToken() orelse {
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection has no current basis", .{});
            return null;
        };
        if (!live.token.eql(current_token)) {
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection is no longer current", .{});
            return null;
        }

        var candidate = repository_selection.buildCompletedSelection(allocator, document, live) catch |err| {
            self.cancelMouseOwner();
            self.status.set("Could not complete source selection: {s}", .{@errorName(err)});
            return null;
        };
        const admitted_document = self.currentSource() orelse {
            candidate.deinit(allocator);
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection is no longer available", .{});
            return null;
        };
        const admitted_token = self.currentContentToken() orelse {
            candidate.deinit(allocator);
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection has no current basis", .{});
            return null;
        };
        if (!candidate.isAdmitted(admitted_document, admitted_token)) {
            candidate.deinit(allocator);
            self.clearCompletedSelectionPreservingViewport(allocator, body_size);
            self.cancelMouseOwner();
            self.status.set("Source selection is no longer current", .{});
            return null;
        }

        const anchor = self.captureSourceViewportAnchor(admitted_document);
        self.clearCompletedSelection(allocator);
        self.completed_selection = candidate;
        candidate = undefined;
        self.cancelMouseOwner();
        const geometry = self.sourceGeometry(body_size, admitted_document);
        self.restoreSourceViewportAnchor(anchor, admitted_document, geometry.visible_source_rows);
        if (self.selectionActionProjection()) |projection| {
            self.viewer.source_vertical_scroll = projection.reveal(
                self.viewer.source_vertical_scroll,
                geometry.visible_source_rows,
            );
        }
        self.status.clear();
        return null;
    }

    fn applySelectionAction(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        action: selection_action.Action,
        body_size: chasen.Size,
    ) ?Command {
        if (action == .clear) {
            if (self.selection_owner != .none or self.completed_selection != null) {
                self.clearLiveAndCompletedSelectionPreservingViewport(allocator, body_size);
                self.status.clear();
            }
            return null;
        }

        if (self.selection_owner.activeKeyboardLineSelection() != null and
            !self.keyboardLineSelectionAdmitted())
        {
            self.invalidateActiveKeyboardSelection(
                allocator,
                body_size,
                "Source selection is no longer current",
            );
            return null;
        }
        // Pointer owners never become keyboard completion transactions. Plain
        // selection keys normally map to `selection_owned_noop`; retain this
        // guard for direct/synthetic messages too.
        if (self.selection_owner.activeMouseOwner()) return null;

        const Adapter = struct {
            state: *RepositoryPageState,
            body_size: chasen.Size,

            pub fn available(adapter: *@This()) bool {
                return adapter.state.selection_owner.activeKeyboardLineSelection() != null or
                    adapter.state.completed_selection != null;
            }

            pub fn copy(adapter: *@This(), owner: std.mem.Allocator) selection_action.CopyError![]u8 {
                if (adapter.state.selection_owner.activeKeyboardLineSelection() != null) {
                    return adapter.state.completeKeyboardLineSelection(owner, adapter.body_size);
                }
                const completed = if (adapter.state.completed_selection) |*value| value else return error.AuthorityInvalid;
                const document = adapter.state.currentSource() orelse return error.AuthorityInvalid;
                const token = adapter.state.currentContentToken() orelse return error.AuthorityInvalid;
                if (!completed.isAdmitted(document, token)) return error.AuthorityInvalid;
                return completed.clipboardText(owner) catch return error.OutOfMemory;
            }

            pub fn clear(adapter: *@This(), owner: std.mem.Allocator) void {
                adapter.state.clearLiveAndCompletedSelectionPreservingViewport(owner, adapter.body_size);
            }
        };
        var adapter: Adapter = .{ .state = self, .body_size = body_size };
        return switch (selection_action.dispatch(allocator, action, &adapter)) {
            .none => null,
            .copy => |clipboard| blk: {
                self.status.clear();
                break :blk .{ .copy_source_selection = clipboard };
            },
            .cleared => blk: {
                self.status.clear();
                break :blk null;
            },
            .authority_invalid => blk: {
                self.status.set("Source selection is no longer current", .{});
                break :blk null;
            },
            .preparation_failed => blk: {
                if (self.selection_owner.activeKeyboardLineSelection() != null)
                    self.status.set("Could not complete source selection; press y to retry", .{})
                else
                    self.status.set("Could not prepare source selection copy", .{});
                break :blk null;
            },
        };
    }

    fn completeKeyboardLineSelection(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        body_size: chasen.Size,
    ) selection_action.CopyError![]u8 {
        const live = self.selection_owner.activeKeyboardLineSelection() orelse return error.AuthorityInvalid;
        const document = self.acceptedCurrentSourceForSelection() orelse return error.AuthorityInvalid;
        const token = self.currentContentToken() orelse return error.AuthorityInvalid;
        if (!live.token.eql(token)) return error.AuthorityInvalid;

        const candidate = repository_selection.buildCompletedSelection(allocator, document, live) catch
            return error.OutOfMemory;

        const admitted_document = self.acceptedCurrentSourceForSelection() orelse {
            var rejected = candidate;
            rejected.deinit(allocator);
            return error.AuthorityInvalid;
        };
        const admitted_token = self.currentContentToken() orelse {
            var rejected = candidate;
            rejected.deinit(allocator);
            return error.AuthorityInvalid;
        };
        if (!candidate.isAdmitted(admitted_document, admitted_token)) {
            var rejected = candidate;
            rejected.deinit(allocator);
            return error.AuthorityInvalid;
        }

        const viewport_anchor = self.captureSourceViewportAnchor(admitted_document);
        const prior = self.completed_selection;
        self.completed_selection = candidate;
        self.clearLiveSelection();
        if (prior) |value| {
            var owned = value;
            owned.deinit(allocator);
        }
        const geometry = self.sourceGeometry(body_size, admitted_document);
        self.restoreSourceViewportAnchor(viewport_anchor, admitted_document, geometry.visible_source_rows);

        return self.completed_selection.?.clipboardText(allocator) catch error.OutOfMemory;
    }

    pub fn mouseToMsg(self: *const RepositoryPageState, point: repository_layout.BodyPoint, button: MouseButton, size: chasen.Size) ?Msg {
        const layout = repository_layout.bodyLayout(size, self.viewer.tree_width, self.viewer.tree_hidden);
        if (layout.tree_visible and point.col < layout.tree_width) return switch (button) {
            .wheel_up => .wheel_up,
            .wheel_down => .wheel_down,
            .left => blk: {
                const body_row = layout.treeBodyRow(point) orelse return .focus_tree;
                const tree = if (self.bundle) |*bundle| &bundle.tree else return null;
                const visible_index = self.viewer.tree_vertical_scroll + body_row;
                const target = self.tree_projection.targetAt(tree, visible_index) orelse return null;
                break :blk if (switch (target) {
                    .repo_root => true,
                    .manifest_node => |node_index| tree.nodes[node_index].kind == .directory,
                })
                    .{ .mouse_toggle_row = body_row }
                else
                    .{ .mouse_row = body_row };
            },
        };
        if (point.col < layout.source_col) return null;
        const source_point = repository_layout.sourceGesturePoint(point, size, self.viewer.tree_width, self.viewer.tree_hidden) orelse return null;
        return switch (button) {
            .wheel_up => if (self.currentSource() != null) .mouse_source_wheel_up else null,
            .wheel_down => if (self.currentSource() != null) .mouse_source_wheel_down else null,
            .left => blk: {
                if (self.selectionActionHit(source_point, size)) |hit| break :blk switch (hit) {
                    .target => |action| .{ .selection_action = action },
                    .inert => null,
                };
                if (self.sourceHeaderPathHit(source_point, size) != null) {
                    break :blk .{ .mouse_source_header_press = source_point };
                }
                if (self.currentSource()) |document| {
                    break :blk if (source_point.row >= self.sourceGeometry(size, document).body_first_row)
                        .{ .mouse_source_press = source_point }
                    else
                        .focus_source;
                }
                break :blk null;
            },
        };
    }
};

fn navigationDismissesIncoming(msg: Msg) bool {
    return switch (msg) {
        .toggle_line_numbers,
        .toggle_tree_visibility,
        .decrease_tree_width,
        .increase_tree_width,
        .cancel_mouse_owner,
        .selection_action,
        .selection_owned_noop,
        .selection_action_unavailable,
        .begin_keyboard_line_selection,
        .keyboard_line_selection_move,
        .cancel_source_search,
        .cancel_file_search,
        .manifest_finished,
        .branch_finished,
        .path_history_finished,
        .document_finished,
        .syntax_finished,
        .change_map_finished,
        => false,
        else => true,
    };
}

fn optionalPathEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Projects only facts proved for the currently selected Repository path.
/// The path and current manifest Git fact remain useful while a document is
/// loading or retained. Line position requires the accepted document;
/// commit history is an independent page-owned authority.
fn projectSourceHeaderPresentation(
    state: *const RepositoryPageState,
    selected_path: []const u8,
) repository_source_header.Presentation {
    const accepted = acceptedSourceHeaderDocument(state, selected_path);
    const line_position: ?repository_source_header.LinePosition = if (accepted) |displayed|
        switch (displayed.value) {
            .source => |source| repository_source_header.LinePosition.fromCursor(
                state.viewer.source_cursor,
                source.contentLineCount(),
            ),
            .inert => null,
        }
    else
        null;
    const history_fact = state.path_history.fact(
        state.requestIdentity(),
        state.root_identity,
        state.manifest_revision,
        selected_path,
    );
    const commit_fact: repository_source_header.CommitFact = if (history_fact) |fact|
        switch (fact) {
            .committed => |seconds| .{ .committed = seconds },
            .uncommitted => .uncommitted,
        }
    else
        .unavailable;
    return .init(
        selected_path,
        line_position,
        sourceHeaderGitState(state, selected_path),
        commit_fact,
    );
}

fn acceptedSourceHeaderDocument(
    state: *const RepositoryPageState,
    selected_path: []const u8,
) ?*const DisplayedDocument {
    const displayed = if (state.displayed_document) |*document| document else return null;
    if (displayed.authority != .accepted or
        displayed.manifest_revision != state.manifest_revision or
        !std.mem.eql(u8, displayed.path, selected_path))
    {
        return null;
    }
    return displayed;
}

fn sourceHeaderGitState(
    state: *const RepositoryPageState,
    selected_path: []const u8,
) repository_source_header.GitState {
    const bundle = if (state.bundle) |*value| value else return .unavailable;
    if (!bundle.status_available) return .unavailable;
    const node_index = bundle.tree.nodeIndexForPath(selected_path, .all) orelse return .unavailable;
    const node = bundle.tree.nodes[node_index];
    if (node.kind != .file or !std.mem.eql(u8, node.path, selected_path)) return .unavailable;
    const change = node.file_change orelse return .clean;
    return switch (change) {
        .added => .added,
        .modified => .modified,
    };
}

test "repository page zero state deinitializes and activation is lazy" {
    var state: RepositoryPageState = .{};
    state.deinit(std.testing.allocator);
    state = .{};
    state.activate(3, .{ .device = 1, .inode = 2 });
    try std.testing.expect(state.initialized);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expectEqual(@as(u64, 3), state.repo_epoch);
}

test "repository transition exports only resolved exact Review context" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    const exact_path = "src/\xff.zig";
    var state: RepositoryPageState = .{
        .repo_epoch = 13,
        .root_identity = identity,
        .selected_path = exact_path,
    };
    defer state.deinit(allocator);

    switch (state.reviewTarget()) {
        .no_context => return error.ExpectedReviewLocation,
        .location => |location| {
            try std.testing.expectEqual(@as(u64, 13), location.repo_epoch);
            try std.testing.expect(location.root_identity.eql(identity));
            try std.testing.expect(std.mem.eql(u8, exact_path, location.path));
            try std.testing.expectEqual(@intFromPtr(state.selected_path.?.ptr), @intFromPtr(location.path.ptr));
        },
    }

    state.selected_path = null;
    try std.testing.expect(state.reviewTarget() == .no_context);
    state.selected_path = exact_path;
    state.root_identity = null;
    try std.testing.expect(state.reviewTarget() == .no_context);
}

test "repository transition pending and unavailable destinations suppress retained context" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .repo_epoch = 13,
        .root_identity = identity,
        .selected_path = "retained.zig",
    };
    defer state.deinit(allocator);

    var pending = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        identity,
        .{ .location = .{ .path = "requested.zig" } },
    );
    state.acceptIncoming(allocator, &pending);
    try std.testing.expect(state.reviewTarget() == .no_context);

    try std.testing.expect(state.incoming.advanceToDocument(21));
    try std.testing.expect(state.reviewTarget() == .no_context);

    try std.testing.expect(state.terminalizeIncoming(.path_not_found));
    try std.testing.expect(state.reviewTarget() == .no_context);

    state.dismissIncoming(allocator);
    switch (state.reviewTarget()) {
        .no_context => return error.ExpectedRetainedReviewLocation,
        .location => |location| try std.testing.expectEqualStrings("retained.zig", location.path),
    }
}

test "repository root keyboard activation preserves expanded descendants and sticky selection" {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "a/one.zig\x00b.zig\x00"));
    const tree = try repository_tree.Tree.build(std.testing.allocator, &document);
    var state: RepositoryPageState = .{ .bundle = .{ .document = document, .tree = tree }, .load_state = .loaded };
    defer state.deinit(std.testing.allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_cursor = 1;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    const directory = state.bundle.?.tree.nodeIndexForPath("a", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
    state.viewer.tree_cursor = 0;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqual(@as(usize, 4), state.tree_projection.visibleLen(&state.bundle.?.tree));
    const first_child = state.tree_projection.targetAt(&state.bundle.?.tree, 1) orelse return error.ExpectedDirectory;
    switch (first_child) {
        .repo_root => return error.ExpectedDirectory,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("a", state.bundle.?.tree.nodes[node_index].path),
    }
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
}

test "repository root activation preserves source and expanded All and Changed directories" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 80, .height = 12 };
    var state = try selectionStateForTest(
        "changed/selected.zig\x00clean/nested/file.zig\x00root.zig\x00",
        "source\n",
    );
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed/selected.zig\x00");

    const changed_file = state.bundle.?.tree.nodeIndexForPath("changed/selected.zig", .all) orelse
        return error.ExpectedChangedFile;
    const clean_file = state.bundle.?.tree.nodeIndexForPath("clean/nested/file.zig", .all) orelse
        return error.ExpectedCleanFile;
    _ = state.tree_projection.revealManifestNode(&state.bundle.?.tree, .all, changed_file) orelse
        return error.ExpectedChangedFile;
    _ = state.tree_projection.revealManifestNode(&state.bundle.?.tree, .all, clean_file) orelse
        return error.ExpectedCleanFile;
    for (state.bundle.?.tree.nodes) |node| {
        if (node.kind == .directory) try std.testing.expect(node.expanded);
    }

    state.viewer.tree_cursor = 0;
    _ = state.applyNavigation(allocator, .toggle_directory, size);
    for (state.bundle.?.tree.nodes) |node| {
        if (node.kind == .directory) try std.testing.expect(node.expanded);
    }
    try std.testing.expectEqualStrings("changed/selected.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("source\n", state.currentSource().?.bytes);
    try std.testing.expectEqual(DisplayedDocument.Authority.accepted, state.displayed_document.?.authority);

    _ = state.tree_projection.revealManifestNode(&state.bundle.?.tree, .all, changed_file) orelse
        return error.ExpectedChangedFile;
    _ = state.tree_projection.revealManifestNode(&state.bundle.?.tree, .all, clean_file) orelse
        return error.ExpectedCleanFile;
    _ = state.applyNavigation(allocator, .toggle_changed_filter, size);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    const root_click = state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, size) orelse
        return error.ExpectedRootMouseTarget;
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 0 }, root_click);
    _ = state.applyNavigation(allocator, root_click, size);
    for (state.bundle.?.tree.nodes) |node| {
        if (node.kind == .directory) try std.testing.expect(node.expanded);
    }

    _ = state.applyNavigation(allocator, .toggle_changed_filter, size);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    const clean = state.bundle.?.tree.nodeIndexForPath("clean", .all) orelse return error.ExpectedCleanDirectory;
    const nested = state.bundle.?.tree.nodeIndexForPath("clean/nested", .all) orelse return error.ExpectedCleanDirectory;
    try std.testing.expect(state.bundle.?.tree.nodes[clean].expanded);
    try std.testing.expect(state.bundle.?.tree.nodes[nested].expanded);
    try std.testing.expectEqualStrings("changed/selected.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("source\n", state.currentSource().?.bytes);
    try std.testing.expectEqual(DisplayedDocument.Authority.accepted, state.displayed_document.?.authority);
}

test "repository manifest replacement refreshes active file search indices" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("old.zig\x00other.zig\x00"),
        .load_state = .loaded,
        .file_search = .{ .mode = true },
    };
    defer state.deinit(allocator);
    try state.file_search.input.insertSlice("old");
    state.refreshFileSearch();
    try std.testing.expectEqual(@as(usize, 1), state.file_search.len);

    var incoming = try bundleForTest("new.zig\x00");
    errdefer incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.no_match);
}

test "repository All replacement restores typed directory cursor beside hidden selection" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    try std.testing.expect(state.bundle.?.tree.toggleVisibleFor(0, .all));
    state.viewer.tree_cursor = 1;

    var incoming = try bundleForTest("dir/selected.zig\x00root.zig\x00");
    errdefer incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_cursor);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
}

test "repository manifest replacement retains minimum tree and selected source" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;

    var incoming = try bundleForTest("dir/selected.zig\x00root.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;

    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 3), state.tree_projection.visibleLen(&state.bundle.?.tree));
    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(!state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
}

test "repository explicit reload restores typed root and directory across outcomes" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.activate(7, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;

    state.requestReload(true);
    var unchanged_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer unchanged_request.deinit(allocator);
    var unchanged: repository_tasks.ManifestFinished = .{
        .identity = unchanged_request.identity,
        .root_identity = unchanged_request.root.identity,
        .generation = unchanged_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(allocator, &unchanged, test_body_size));
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);

    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    const directory_visible = std.mem.indexOfScalar(
        usize,
        state.bundle.?.tree.visibleNodes(),
        directory,
    ) orelse return error.ExpectedVisibleDirectory;
    try std.testing.expect(state.bundle.?.tree.toggleVisibleFor(directory_visible, .all));
    state.viewer.tree_cursor = state.tree_projection.visibleIndexForTarget(
        &state.bundle.?.tree,
        .{ .manifest_node = directory },
    ) orelse return error.ExpectedVisibleDirectory;

    state.requestReload(true);
    var changed_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer changed_request.deinit(allocator);
    var changed: repository_tasks.ManifestFinished = .{
        .identity = changed_request.identity,
        .root_identity = changed_request.root.identity,
        .generation = changed_request.generation,
        .result = .{ .loaded = try bundleForTest("dir/selected.zig\x00new.zig\x00root.zig\x00") },
    };
    defer changed.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &changed, test_body_size));
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    const restored = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedRestoredTarget;
    switch (restored) {
        .repo_root => return error.ExpectedDirectory,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("dir", state.bundle.?.tree.nodes[node_index].path),
    }
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
    try std.testing.expect(state.needs_document_revalidation);
}

test "repository manifest replacement falls deleted directory cursor to visible ancestor" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a/nested/selected.zig\x00a/kept.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("a/nested/selected.zig", .all);
    const nested = state.bundle.?.tree.nodeIndexForPath("a/nested", .all) orelse return error.ExpectedDirectory;
    state.viewer.tree_cursor = state.tree_projection.revealManifestNode(
        &state.bundle.?.tree,
        .all,
        nested,
    ) orelse return error.ExpectedVisibleDirectory;

    var incoming = try bundleForTest("a/kept.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;

    const target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedRestoredTarget;
    switch (target) {
        .repo_root => return error.ExpectedDirectoryAncestor,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("a", state.bundle.?.tree.nodes[node_index].path),
    }
}

test "repository file search reveals collapsed ancestors before selecting result" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/target.zig\x00other.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("other.zig", .all);
    state.file_search.mode = true;
    try state.file_search.input.insertSlice("target");
    state.refreshFileSearch();

    _ = state.applyNavigation(allocator, .submit_file_search, .{ .width = 80, .height = 10 });

    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    const selected_target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedSearchTarget;
    switch (selected_target) {
        .repo_root => return error.ExpectedFileTarget,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("dir/target.zig", state.bundle.?.tree.nodes[node_index].path),
    }
}

test "repository empty file search accepts the focused exact candidate" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("alpha.zig\x00beta.zig\x00"),
        .load_state = .loaded,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("beta.zig", .all);
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);

    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_previous, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
}

test "repository empty file search retains authoritative zero-candidate prompt" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest(""),
        .load_state = .loaded,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 8 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
}

test "repository hidden tree gives source full geometry and restores retained focus" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest(
        "a.zig\x00b.zig\x00c.zig\x00d.zig\x00e.zig\x00f.zig\x00",
        "one\ntwo\nthree\n",
    );
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 6 };
    state.viewer.focus = .tree;
    state.viewer.tree_width = 42;
    state.viewer.tree_cursor = 4;
    state.viewer.tree_vertical_scroll = 2;
    state.viewer.tree_horizontal_scroll = 7;
    const selected = state.selected_path.?;

    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.tree_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.tree_horizontal_scroll);
    try std.testing.expectEqualStrings(selected, state.selected_path.?);
    const hidden_layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expect(!hidden_layout.tree_visible);
    try std.testing.expectEqual(@as(u16, 0), hidden_layout.source_col);
    try std.testing.expectEqual(size.width, hidden_layout.source_width);
    try std.testing.expectEqual(size.width, state.sourceGeometry(size, state.currentSource().?).width);
    try std.testing.expectEqual(
        Msg.focus_source,
        state.mouseToMsg(.{ .col = 0, .row = 0 }, .left, size).?,
    );
    try std.testing.expectEqual(
        repository_layout.BodyPoint{ .col = 4, .row = 2 },
        repository_layout.sourceGesturePoint(.{ .col = 4, .row = 2 }, size, state.viewer.tree_width, true).?,
    );

    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.tree_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.tree_horizontal_scroll);

    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    const repo_epoch = state.repo_epoch;
    const root_identity = state.root_identity.?;
    state.deactivate();
    state.activate(repo_epoch, root_identity);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
}

test "repository hidden-tree file search restores on cancel and commits visible on success" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/target.zig\x00other.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("other.zig", .all);
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);

    state.file_search.input.clear();
    state.refreshFileSearch();
    try state.file_search.input.insertSlice("missing");
    state.refreshFileSearch();
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("other.zig", state.selected_path.?);

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
}

test "repository changed file search retains its transaction when status basis is unavailable" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00"),
        .load_state = .loaded,
        .file_visibility = .changed,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("target.zig", .all);
    const size: chasen.Size = .{ .width = 80, .height = 8 };
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(state.file_search.selectedNode() == null);

    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("target.zig", state.selected_path.?);
}

test "repository changed file search reclassifies status-only availability transitions" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M target.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("target.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 8 });
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, .{ .width = 80, .height = 8 });
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, .{ .width = 80, .height = 8 });
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(state.file_search.selectedNode() != null);

    var unavailable_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer unavailable_request.deinit(allocator);
    var unavailable = repository_tasks.ManifestFinished{
        .identity = unavailable_request.identity,
        .root_identity = unavailable_request.root.identity,
        .generation = unavailable_request.generation,
        .result = .{ .status_changed = .unavailable },
    };
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &unavailable, test_body_size));
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.selectedNode() == null);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .submit_file_search, .{ .width = 80, .height = 8 });
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(!state.file_search.projection_available);

    state.needs_revalidation = true;
    var available_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer available_request.deinit(allocator);
    var available_empty = repository_tasks.ManifestFinished{
        .identity = available_request.identity,
        .root_identity = available_request.root.identity,
        .generation = available_request.generation,
        .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
            allocator,
            try allocator.dupe(u8, ""),
        ) } },
    };
    defer available_empty.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &available_empty, test_body_size));
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.selectedNode() == null);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
}

test "repository hidden tree keeps source focus when document becomes inert" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "visible source\n");
    defer state.deinit(allocator);
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    state.document_generation = 8;
    state.pending_document_generation = 8;

    var finished: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .inert = .binary },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.currentSource() == null);
    try std.testing.expect(state.displayed_document.?.value == .inert);
}

test "repository replacement retains hidden preference behind temporary search reveal" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00"),
        .load_state = .loaded,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, .{ .width = 80, .height = 10 });
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expect(state.file_search.restore_tree_hidden);

    state.repositoryChanged(allocator, 9, .{ .device = 8, .inode = 13 });
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expect(state.selected_path == null);
}

fn bundleForTest(bytes: []const u8) !repository_tasks.Bundle {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    return .{ .tree = try repository_tree.Tree.build(std.testing.allocator, &document), .document = document };
}

const test_body_size: chasen.Size = .{ .width = 80, .height = 24 };

fn expectProjectedPathForTest(
    state: *const RepositoryPageState,
    visible_index: usize,
    expected_path: []const u8,
) !void {
    const tree = &state.bundle.?.tree;
    const target = state.tree_projection.targetAt(tree, visible_index) orelse
        return error.ExpectedProjectedPath;
    switch (target) {
        .repo_root => return error.ExpectedManifestPath,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            expected_path,
            tree.nodes[node_index].path,
        ),
    }
}

fn selectionStateForTest(paths: []const u8, content: []const u8) !RepositoryPageState {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = .{ .device = 4, .inode = 5 },
        .bundle = try bundleForTest(paths),
        .load_state = .loaded,
        .freshness = .fresh,
        .manifest_revision = 6,
        .source_revision = 7,
    };
    errdefer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_cursor = 1;
    const bytes = try allocator.dupe(u8, content);
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    errdefer document.deinit(allocator);
    const path = try allocator.dupe(u8, state.selected_path.?);
    state.displayed_document = .{
        .path = path,
        .manifest_revision = state.manifest_revision,
        .source_revision = 7,
        .authority = .accepted,
        .value = .{ .source = document },
    };
    return state;
}

fn installFirstLineCandidateForTest(
    state: *RepositoryPageState,
    allocator: std.mem.Allocator,
) !void {
    const document = state.currentSource() orelse return error.ExpectedSource;
    var drag = repository_selection.DragSelection.init(
        state.currentContentToken() orelse return error.ExpectedContentToken,
        .line,
        repository_selection.pointFromLine(0),
    );
    drag.moved = true;
    var completed = try repository_selection.buildCompletedSelection(allocator, document, drag);
    state.clearCompletedSelection(allocator);
    state.completed_selection = completed;
    completed = undefined;
}

test "repository keyboard line selection begins moves crosses and copies exact lines" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var state = try selectionStateForTest(
        "main.zig\x00",
        "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n",
    );
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.viewer.focus = .source;
    state.viewer.source_cursor = 2;

    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(state.activeKeyboardLineSelection());
    try std.testing.expect(!state.activeMouseOwner());
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.activeBorrowedSourceRange());
    try std.testing.expectEqual(@as(usize, 1), state.sourceSelectionPresentation().?.line_count);
    try std.testing.expectEqual(SourceSelectionPresentation.Owner.active_keyboard, state.sourceSelectionPresentation().?.owner);
    try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

    _ = state.applyNavigation(allocator, .{ .keyboard_line_selection_move = .down }, size);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 2), state.sourceSelectionPresentation().?.line_count);
    _ = state.applyNavigation(allocator, .{ .keyboard_line_selection_move = .up }, size);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.sourceSelectionPresentation().?.line_count);
    _ = state.applyNavigation(allocator, .{ .keyboard_line_selection_move = .up }, size);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    const crossed = state.selection_owner.activeKeyboardLineSelection().?;
    try std.testing.expectEqual(@as(usize, 1), crossed.range().start.line_index);
    try std.testing.expectEqual(@as(usize, 2), crossed.range().end.line_index);
    try std.testing.expectEqual(@as(usize, 2), crossed.lineCount());

    const focus_before_wheel = crossed.focus;
    const cursor_before_wheel = state.viewer.source_cursor;
    _ = state.applyNavigation(allocator, .mouse_source_wheel_down, size);
    try std.testing.expectEqual(cursor_before_wheel, state.viewer.source_cursor);
    try std.testing.expect(std.meta.eql(focus_before_wheel, state.selection_owner.activeKeyboardLineSelection().?.focus));

    _ = state.applyNavigation(allocator, .toggle_line_numbers, size);
    _ = state.applyNavigation(allocator, .increase_tree_width, size);
    _ = state.applyNavigation(allocator, .scroll_right, size);
    try std.testing.expect(state.activeKeyboardLineSelection());
    _ = state.applyNavigation(allocator, .enter_source_search, size);
    _ = state.applyNavigation(allocator, .{ .source_search_insert = 'x' }, size);
    _ = state.applyNavigation(allocator, .cancel_source_search, size);
    try std.testing.expect(state.activeKeyboardLineSelection());
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(state.activeKeyboardLineSelection());

    _ = state.applyNavigation(allocator, .selection_action_unavailable, size);
    try std.testing.expect(state.activeKeyboardLineSelection());
    try std.testing.expectEqualStrings("Ask is not available for this selection", state.status.text());

    const action_geometry = state.sourceGeometry(size, state.currentSource().?);
    const action_projection = state.selectionActionProjection().?;
    const controls_offset = action_projection.actionScreenRow(
        .controls,
        state.viewer.source_vertical_scroll,
        action_geometry.visible_source_rows,
    ) orelse return error.ExpectedSelectionControls;
    const page_layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(
        Msg{ .selection_action = .copy },
        state.mouseToMsg(.{
            .col = page_layout.source_col,
            .row = action_geometry.body_first_row + @as(u16, @intCast(controls_offset)),
        }, .left, size).?,
    );

    var copied = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer copied.deinit(allocator);
    var command = copied.takeCommand() orelse return error.ExpectedSourceCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_source_selection => |text| try std.testing.expectEqualStrings("one\ntwo\n", text),
        else => return error.ExpectedSourceCopyCommand,
    }
    try std.testing.expect(!state.activeBorrowedSourceRange());
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("one\ntwo\n", state.completed_selection.?.text);
    try std.testing.expectEqual(SourceSelectionPresentation.Owner.completed, state.sourceSelectionPresentation().?.owner);

    _ = state.applyNavigation(allocator, .selection_action_unavailable, size);
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("Ask is not available for this selection", state.status.text());

    _ = state.applyNavigation(allocator, .{ .selection_action = .clear }, size);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expect(state.selection_owner == .none);
    try std.testing.expect(state.selectionActionProjection() == null);

    state.viewer.focus = .tree;
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(!state.activeKeyboardLineSelection());
    try std.testing.expectEqualStrings("Keyboard selection requires source focus", state.status.text());

    state.viewer.tree_hidden = true;
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(state.activeKeyboardLineSelection());
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    _ = state.applyNavigation(allocator, .{ .selection_action = .clear }, size);
    state.viewer.tree_hidden = false;
    state.viewer.focus = .source;
    state.viewer.source_cursor = 2;
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("seven") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.source_cursor);
    try std.testing.expect(!state.activeKeyboardLineSelection());
}

test "repository keyboard line selection saturates and movement allocates nothing" {
    const backing = std.testing.allocator;
    const size: chasen.Size = .{ .width = 50, .height = 5 };
    var state = try selectionStateForTest("main.zig\x00", "zero\none\ntwo\n");
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    defer state.deinit(failing.allocator());
    state.viewer.focus = .source;
    state.viewer.source_cursor = 0;
    _ = state.applyNavigation(failing.allocator(), .begin_keyboard_line_selection, size);
    try std.testing.expect(state.activeKeyboardLineSelection());

    _ = state.applyNavigation(failing.allocator(), .{ .keyboard_line_selection_move = .up }, size);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.selection_owner.activeKeyboardLineSelection().?.lineCount());
    for (0..8) |_| _ = state.applyNavigation(failing.allocator(), .{ .keyboard_line_selection_move = .down }, size);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 3), state.selection_owner.activeKeyboardLineSelection().?.lineCount());
}

test "repository keyboard line selection preserves retry owners across allocation failures" {
    const backing = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };

    {
        var state = try selectionStateForTest("main.zig\x00", "zero\none\ntwo\n");
        try installFirstLineCandidateForTest(&state, backing);
        state.viewer.focus = .source;
        state.viewer.source_cursor = 1;
        _ = state.applyNavigation(backing, .begin_keyboard_line_selection, size);
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
        defer state.deinit(failing.allocator());

        var failed = state.applyNavigation(failing.allocator(), .{ .selection_action = .copy }, size);
        defer failed.deinit(failing.allocator());
        try std.testing.expect(failed.command == null);
        try std.testing.expect(state.activeKeyboardLineSelection());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);
        _ = state.applyNavigation(failing.allocator(), .{ .selection_action = .clear }, size);
        try std.testing.expect(!state.activeKeyboardLineSelection());
        try std.testing.expect(state.completed_selection == null);
    }

    {
        var state = try selectionStateForTest("main.zig\x00", "zero\none\ntwo\n");
        try installFirstLineCandidateForTest(&state, backing);
        state.viewer.focus = .source;
        state.viewer.source_cursor = 1;
        _ = state.applyNavigation(backing, .begin_keyboard_line_selection, size);
        // Candidate text and token path allocate first; fail the separate
        // clipboard duplicate after the new completed owner is installed.
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 2 });
        defer state.deinit(failing.allocator());

        var failed = state.applyNavigation(failing.allocator(), .{ .selection_action = .copy }, size);
        defer failed.deinit(failing.allocator());
        try std.testing.expect(failed.command == null);
        try std.testing.expect(!state.activeKeyboardLineSelection());
        try std.testing.expectEqualStrings("one", state.completed_selection.?.text);
        try std.testing.expectEqualStrings("Could not prepare source selection copy", state.status.text());
    }

    {
        var state = try selectionStateForTest("main.zig\x00", "zero\none\ntwo\n");
        defer state.deinit(backing);
        try installFirstLineCandidateForTest(&state, backing);
        state.viewer.focus = .source;
        state.viewer.source_cursor = 1;
        _ = state.applyNavigation(backing, .begin_keyboard_line_selection, size);
        switch (state.selection_owner) {
            .source => |*live| live.token.repo_epoch +%= 1,
            .none, .source_header => return error.ExpectedKeyboardSelection,
        }

        var rejected = state.applyNavigation(backing, .{ .selection_action = .copy }, size);
        defer rejected.deinit(backing);
        try std.testing.expect(rejected.command == null);
        try std.testing.expect(!state.activeKeyboardLineSelection());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);
    }
}

test "repository keyboard line selection reload clears borrow and retains prior owned candidate" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var state = try selectionStateForTest("main.zig\x00", "zero\none\ntwo\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.viewer.focus = .source;
    state.viewer.source_cursor = 1;
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(state.activeBorrowedSourceRange());

    state.requestReload(true);
    try std.testing.expect(!state.activeBorrowedSourceRange());
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

    state.markRequestPreparationFailed(error.OutOfMemory);
    try std.testing.expect(!state.activeBorrowedSourceRange());
    try std.testing.expect(state.completed_selection != null);
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(!state.activeKeyboardLineSelection());
    var copied = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer copied.deinit(allocator);
    try std.testing.expect(copied.command != null);
    try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);
}

test "repository keyboard line selection document revalidation clears borrow across request failure terminals" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var root = try TestRoot.init();
    defer root.deinit();

    inline for (.{ false, true }) |fingerprint_mismatch| {
        var state = try selectionStateForTest(
            "main.zig\x00",
            "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        );
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        try installFirstLineCandidateForTest(&state, allocator);
        state.viewer.focus = .source;
        state.viewer.source_cursor = 2;
        _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
        state.viewer.source_vertical_scroll = 5;
        try std.testing.expect(state.activeBorrowedSourceRange());
        const viewport_before = state.captureSourceViewportAnchor(state.currentSource().?);
        try std.testing.expectEqual(@as(usize, 3), viewport_before.semantic_source);

        const generation: u64 = if (fingerprint_mismatch) 42 else 41;
        state.change_map_generation = generation;
        state.pending_change_map_generation = generation;
        var mismatch_finished: repository_tasks.ChangeMapFinished = .{
            .identity = .{
                .origin = .repository,
                .repo_epoch = state.repo_epoch,
                .activation_id = state.activation_id,
            },
            .root_identity = state.root_identity.?,
            .generation = generation,
            .manifest_revision = state.manifest_revision,
            .source_revision = state.displayed_document.?.source_revision,
            .path = try allocator.dupe(u8, state.selected_path.?),
            .fingerprint = state.currentSource().?.fingerprint,
            .content_line_count = state.currentSource().?.contentLineCount(),
            .result = .unavailable,
        };
        defer mismatch_finished.deinit(allocator);
        if (fingerprint_mismatch) {
            mismatch_finished.fingerprint = .init("newer source snapshot");
        } else {
            mismatch_finished.content_line_count += 1;
        }

        try std.testing.expectEqual(
            ApplyOutcome.discarded,
            state.applyChangeMapFinished(allocator, &mismatch_finished),
        );
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expectEqual(
            DisplayedDocument.Authority.revalidation_required,
            state.displayed_document.?.authority,
        );
        try std.testing.expect(state.needs_document_revalidation);
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);
        const viewport_after = state.captureSourceViewportAnchor(state.currentSource().?);
        try std.testing.expectEqual(viewport_before.semantic_source, viewport_after.semantic_source);
        try std.testing.expectEqual(viewport_before.signed_screen_delta, viewport_after.signed_screen_delta);

        const pending_context = state.inputContext(.{});
        try std.testing.expect(pending_context.selection_owner == .none);
        try std.testing.expect(pending_context.retained_selection_action_available);
        const move_down = repository_input.keyToMsg(Msg, pending_context, .{ .codepoint = 'j' }).?;
        const move_up = repository_input.keyToMsg(Msg, pending_context, .{ .codepoint = 'k' }).?;
        try std.testing.expectEqual(Msg.move_down, move_down);
        try std.testing.expectEqual(Msg.move_up, move_up);
        _ = state.applyNavigation(allocator, move_down, size);
        try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
        _ = state.applyNavigation(allocator, move_up, size);
        try std.testing.expectEqual(@as(usize, 2), state.viewer.source_cursor);

        const copy = repository_input.keyToMsg(Msg, pending_context, .{ .codepoint = 'y' }).?;
        try std.testing.expectEqual(Msg{ .selection_action = .copy }, copy);
        var copied = state.applyNavigation(allocator, copy, size);
        defer copied.deinit(allocator);
        var copy_command = copied.takeCommand() orelse return error.ExpectedSourceCopyCommand;
        defer copy_command.deinit(allocator);
        switch (copy_command) {
            .copy_source_selection => |text| try std.testing.expectEqualStrings("zero", text),
            else => return error.ExpectedSourceCopyCommand,
        }
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try std.testing.expectError(
            error.OutOfMemory,
            state.prepareDocumentRequest(failing.allocator(), &root.capability),
        );
        state.markDocumentRequestPreparationFailed(error.OutOfMemory);
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);
        try std.testing.expect(state.wantsDocumentRequest());

        var request = try state.prepareDocumentRequest(allocator, &root.capability);
        defer request.deinit(allocator);
        try std.testing.expect(state.pending_document_generation == request.generation);
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expect(state.inputContext(.{}).selection_owner == .none);
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

        state.rejectDocumentSpawn(request.generation);
        try std.testing.expect(state.pending_document_generation == null);
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

        const stale_bytes = try allocator.dupe(
            u8,
            "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        );
        var stale_document: repository_tasks.DocumentFinished = .{
            .identity = request.identity,
            .root_identity = request.root.identity,
            .generation = request.generation,
            .manifest_revision = request.manifest_revision,
            .path = try allocator.dupe(u8, request.path),
            .value = .{ .source = try source_document.Document.initOwned(
                allocator,
                stale_bytes,
                .init(stale_bytes),
            ) },
        };
        defer stale_document.deinit(allocator);
        try std.testing.expectEqual(
            ApplyOutcome.discarded,
            state.applyDocumentFinished(allocator, &stale_document),
        );
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

        const clear = repository_input.keyToMsg(
            Msg,
            state.inputContext(.{}),
            .{ .codepoint = chasen.Key.escape },
        ).?;
        try std.testing.expectEqual(Msg{ .selection_action = .clear }, clear);
        var cleared = state.applyNavigation(allocator, clear, size);
        defer cleared.deinit(allocator);
        try std.testing.expect(cleared.command == null);
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expect(state.completed_selection == null);
    }

    inline for (.{ false, true }) |fingerprint_mismatch| {
        var state = try selectionStateForTest(
            "main.zig\x00",
            "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        );
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.viewer.focus = .source;
        state.viewer.source_cursor = 2;
        _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
        state.viewer.source_vertical_scroll = 5;
        const viewport_before = state.captureSourceViewportAnchor(state.currentSource().?);
        try std.testing.expectEqual(@as(usize, 3), viewport_before.semantic_source);

        const generation: u64 = if (fingerprint_mismatch) 52 else 51;
        state.change_map_generation = generation;
        state.pending_change_map_generation = generation;
        var mismatch_finished: repository_tasks.ChangeMapFinished = .{
            .identity = .{
                .origin = .repository,
                .repo_epoch = state.repo_epoch,
                .activation_id = state.activation_id,
            },
            .root_identity = state.root_identity.?,
            .generation = generation,
            .manifest_revision = state.manifest_revision,
            .source_revision = state.displayed_document.?.source_revision,
            .path = try allocator.dupe(u8, state.selected_path.?),
            .fingerprint = state.currentSource().?.fingerprint,
            .content_line_count = state.currentSource().?.contentLineCount(),
            .result = .unavailable,
        };
        defer mismatch_finished.deinit(allocator);
        if (fingerprint_mismatch)
            mismatch_finished.fingerprint = .init("newer source snapshot")
        else
            mismatch_finished.content_line_count += 1;

        try std.testing.expectEqual(
            ApplyOutcome.discarded,
            state.applyChangeMapFinished(allocator, &mismatch_finished),
        );
        try std.testing.expect(!state.activeBorrowedSourceRange());
        try std.testing.expect(state.completed_selection == null);
        const viewport_after = state.captureSourceViewportAnchor(state.currentSource().?);
        try std.testing.expectEqual(viewport_before.semantic_source, viewport_after.semantic_source);
        try std.testing.expectEqual(viewport_before.signed_screen_delta, viewport_after.signed_screen_delta);
    }
}

test "repository mouse and header owners keep prior candidate until all-owner clear" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    inline for (.{ false, true }) |header_owner| {
        var state = try selectionStateForTest("main.zig\x00", "zero\none\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        if (!header_owner) {
            state.selection_owner = .{ .source = repository_selection.DragSelection.init(
                state.currentContentToken().?,
                .line,
                repository_selection.pointFromLine(0),
            ) };
        } else {
            state.selection_owner = .{ .source_header = .{ .identity = state.currentSourceHeaderIdentity().? } };
        }

        _ = state.applyNavigation(allocator, .selection_owned_noop, size);
        try std.testing.expect(state.activeMouseOwner());
        try std.testing.expect(state.completed_selection != null);
        var synthetic_copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
        defer synthetic_copy.deinit(allocator);
        try std.testing.expect(synthetic_copy.command == null);
        try std.testing.expect(state.activeMouseOwner());
        try std.testing.expectEqualStrings("zero", state.completed_selection.?.text);

        _ = state.applyNavigation(allocator, .{ .selection_action = .clear }, size);
        try std.testing.expect(!state.activeMouseOwner());
        try std.testing.expect(state.completed_selection == null);
    }

    inline for (.{ false, true }) |retain_prior| inline for (.{ false, true }) |header_press| {
        var replaced = try selectionStateForTest(
            "main.zig\x00",
            "zero\none\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        );
        defer replaced.deinit(allocator);
        try installFirstLineCandidateForTest(&replaced, allocator);
        if (!retain_prior) replaced.clearCompletedSelection(allocator);
        replaced.viewer.focus = .source;
        replaced.viewer.source_cursor = 2;
        _ = replaced.applyNavigation(allocator, .begin_keyboard_line_selection, size);
        replaced.viewer.source_vertical_scroll = 5;
        const viewport_before = replaced.captureSourceViewportAnchor(replaced.currentSource().?);
        try std.testing.expectEqual(@as(usize, 3), viewport_before.semantic_source);

        if (header_press) {
            const page_layout = repository_layout.bodyLayout(size, replaced.viewer.tree_width, replaced.viewer.tree_hidden);
            const header_target = repository_source_header.layout(
                page_layout.source_width,
                replaced.sourceHeaderPresentation().?,
            ).path_target orelse return error.ExpectedPathTarget;
            _ = replaced.applyNavigation(allocator, .{ .mouse_source_header_press = .{
                .col = header_target.col,
                .row = repository_source_geometry.source_path_row,
            } }, size);
            try std.testing.expect(replaced.selection_owner.activeSourceHeader() != null);
        } else {
            const geometry = replaced.sourceGeometry(size, replaced.currentSource().?);
            const pressed_line = geometry.contentLineAtProjected(
                geometry.body_first_row,
                replaced.viewer.source_vertical_scroll,
                replaced.currentSource().?,
                replaced.selectionActionProjection(),
            ) orelse return error.ExpectedSourceLine;
            try std.testing.expectEqual(@as(usize, 3), pressed_line);
            _ = replaced.applyNavigation(allocator, .{ .mouse_source_press = .{
                .col = geometry.text_col,
                .row = geometry.body_first_row,
            } }, size);
            try std.testing.expect(replaced.activeMouseSourceRange());
            try std.testing.expectEqual(pressed_line, replaced.viewer.source_cursor);
        }
        try std.testing.expect(!replaced.activeKeyboardLineSelection());
        try std.testing.expectEqual(retain_prior, replaced.completed_selection != null);
        if (retain_prior) try std.testing.expectEqualStrings("zero", replaced.completed_selection.?.text);
        const viewport_after = replaced.captureSourceViewportAnchor(replaced.currentSource().?);
        try std.testing.expectEqual(viewport_before.semantic_source, viewport_after.semantic_source);
        try std.testing.expectEqual(viewport_before.signed_screen_delta, viewport_after.signed_screen_delta);
    };
}

fn expectDocumentReplacementCandidateForTest(content: ?[]const u8, retained: bool) !void {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.document_generation = 8;
    state.pending_document_generation = 8;

    const value: repository_tasks.DocumentValue = if (content) |bytes| blk: {
        const owned = try allocator.dupe(u8, bytes);
        break :blk .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) };
    } else .{ .inert = .binary };
    var finished: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = value,
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(retained, state.completed_selection != null);
    if (retained) {
        try std.testing.expectEqualStrings("old source", state.completed_selection.?.text);
        try std.testing.expect(state.completed_selection.?.token.view().eql(state.currentContentToken().?));
    }
}

fn applyBundleStatusForTest(bundle: *repository_tasks.Bundle, bytes: []const u8) !void {
    var index = try repository_change_index.parseOwned(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, bytes),
    );
    defer index.deinit(std.testing.allocator);
    _ = bundle.tree.applyChangeIndex(&index);
    bundle.status_fingerprint = index.fingerprint;
    bundle.status_available = true;
}

test "repository source header projects exact accepted source facts" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    state.viewer.source_cursor = 99;
    const modified_at: std.Io.Timestamp = .{
        .nanoseconds = 951_827_640 * std.time.ns_per_s,
    };
    state.displayed_document.?.metadata = .{ .modified_at = modified_at };
    try applyBundleStatusForTest(&state.bundle.?, " M main.zig\x00");

    const presentation = state.sourceHeaderPresentation().?;
    try std.testing.expectEqual(
        repository_source_header.LinePosition{ .current = 2, .total = 2 },
        presentation.line_position.?,
    );
    try std.testing.expectEqual(repository_source_header.GitState.modified, presentation.git_state);
    try std.testing.expect(presentation.commit_fact == .unavailable);
    try std.testing.expectEqualStrings("main.zig", presentation.raw_path);
}

test "repository source header projects empty accepted source as zero of zero" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("empty.zig\x00", "");
    defer state.deinit(allocator);
    state.viewer.source_cursor = 99;
    try applyBundleStatusForTest(&state.bundle.?, "");

    const presentation = state.sourceHeaderPresentation().?;
    try std.testing.expectEqual(
        repository_source_header.LinePosition{ .current = 0, .total = 0 },
        presentation.line_position.?,
    );
    try std.testing.expectEqual(repository_source_header.GitState.clean, presentation.git_state);
}

test "repository source header does not project inert filesystem mtime as Git history" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("binary.dat\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const modified_at: std.Io.Timestamp = .{ .nanoseconds = 123_456_789 };
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .authority = .accepted,
        .value = .{ .inert = .binary },
        .metadata = .{ .modified_at = modified_at },
    };
    try applyBundleStatusForTest(&state.bundle.?, "?? binary.dat\x00");

    const presentation = state.sourceHeaderPresentation().?;
    try std.testing.expect(presentation.line_position == null);
    try std.testing.expectEqual(repository_source_header.GitState.added, presentation.git_state);
    try std.testing.expect(presentation.commit_fact == .unavailable);
}

test "repository source header retained document cannot claim line or commit history" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    state.displayed_document.?.metadata = .{ .modified_at = .{ .nanoseconds = 123 } };
    state.displayed_document.?.authority = .revalidation_required;
    try applyBundleStatusForTest(&state.bundle.?, "?? main.zig\x00");

    var presentation = state.sourceHeaderPresentation().?;
    try std.testing.expect(presentation.line_position == null);
    try std.testing.expect(presentation.commit_fact == .unavailable);
    try std.testing.expectEqual(repository_source_header.GitState.added, presentation.git_state);

    state.displayed_document.?.authority = .accepted;
    state.displayed_document.?.manifest_revision +%= 1;
    presentation = state.sourceHeaderPresentation().?;
    try std.testing.expect(presentation.line_position == null);
    try std.testing.expect(presentation.commit_fact == .unavailable);
    try std.testing.expectEqual(repository_source_header.GitState.added, presentation.git_state);
}

test "repository source header status requires an exact usable manifest node" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var presentation = state.sourceHeaderPresentation().?;
    try std.testing.expectEqual(repository_source_header.GitState.unavailable, presentation.git_state);

    try applyBundleStatusForTest(&state.bundle.?, "");
    presentation = state.sourceHeaderPresentation().?;
    try std.testing.expectEqual(repository_source_header.GitState.clean, presentation.git_state);

    presentation = projectSourceHeaderPresentation(&state, "missing.zig");
    try std.testing.expectEqual(repository_source_header.GitState.unavailable, presentation.git_state);
    try std.testing.expect(presentation.line_position == null);
    try std.testing.expect(presentation.commit_fact == .unavailable);
}

test "repository source header copies a loading byte-exact path and excludes chrome" {
    const allocator = std.testing.allocator;
    const raw_path = "src/\xff-main.zig";
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 4,
        .repo_epoch = 3,
        .root_identity = .{ .device = 5, .inode = 6 },
        .bundle = try bundleForTest(raw_path ++ "\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const size: chasen.Size = .{ .width = 72, .height = 8 };
    const page_layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const header_layout = repository_source_header.layout(
        page_layout.source_width,
        state.sourceHeaderPresentation().?,
    );
    const target = header_layout.path_target orelse return error.ExpectedPathTarget;
    const local: repository_layout.BodyPoint = .{ .col = target.col, .row = repository_source_geometry.source_path_row };
    const press = state.mouseToMsg(.{
        .col = page_layout.source_col + local.col,
        .row = local.row,
    }, .left, size) orelse return error.ExpectedHeaderPress;
    try std.testing.expectEqual(Msg{ .mouse_source_header_press = local }, press);

    if (header_layout.git) |git| {
        try std.testing.expect(state.mouseToMsg(.{
            .col = page_layout.source_col + git.region.col,
            .row = repository_source_geometry.source_path_row,
        }, .left, size) == null);
    }
    try std.testing.expect(state.mouseToMsg(.{
        .col = page_layout.source_col + target.col,
        .row = repository_source_geometry.source_search_or_rule_row,
    }, .left, size) == null);

    var pressed = state.applyNavigation(allocator, press, size);
    defer pressed.deinit(allocator);
    try std.testing.expect(state.activeMouseOwner());
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.sourceHeaderSelected());
    try std.testing.expect(state.completed_selection == null);

    // A click release copies the complete model path even though its rendered
    // form escapes the invalid byte and may be clipped by the terminal.
    var released = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer released.deinit(allocator);
    var command = released.takeCommand() orelse return error.ExpectedHeaderCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_source_header_path => |path| try std.testing.expectEqualSlices(u8, raw_path, path),
        else => return error.ExpectedHeaderCopyCommand,
    }
    try std.testing.expect(!state.activeMouseOwner());
    try std.testing.expect(state.completed_selection == null);
}

test "repository source header locks gesture kind and revalidates release identity" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 72, .height = 8 };
    const page_layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const header_layout = repository_source_header.layout(
        page_layout.source_width,
        state.sourceHeaderPresentation().?,
    );
    const target = header_layout.path_target orelse return error.ExpectedPathTarget;
    const header_point: repository_layout.BodyPoint = .{ .col = target.col, .row = repository_source_geometry.source_path_row };
    const source_geometry = state.sourceGeometry(size, state.currentSource().?);
    const body_point: repository_layout.BodyPoint = .{ .col = source_geometry.text_col, .row = source_geometry.body_first_row };

    _ = state.applyNavigation(allocator, .{ .mouse_source_header_press = header_point }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = body_point }, size);
    try std.testing.expect(state.selection_owner.activeSourceHeader() != null);
    try std.testing.expect(!state.activeMouseSourceRange());
    var header_release = state.applyNavigation(allocator, .{ .mouse_owner_release = body_point }, size);
    defer header_release.deinit(allocator);
    try std.testing.expect(header_release.command != null);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = body_point }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = header_point }, size);
    try std.testing.expect(state.selection_owner.activeSource() != null);
    try std.testing.expect(state.activeMouseSourceRange());
    state.cancelMouseOwner();

    _ = state.applyNavigation(allocator, .{ .mouse_source_header_press = header_point }, size);
    state.manifest_revision +%= 1;
    var stale = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer stale.deinit(allocator);
    try std.testing.expect(stale.command == null);
    try std.testing.expect(!state.activeMouseOwner());
}

test "repository source header bounds clone failure and retains exact unchanged manifest" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 4,
        .repo_epoch = 3,
        .root_identity = .{ .device = 5, .inode = 6 },
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const size: chasen.Size = .{ .width = 72, .height = 8 };
    const page_layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const target = repository_source_header.layout(
        page_layout.source_width,
        state.sourceHeaderPresentation().?,
    ).path_target orelse return error.ExpectedPathTarget;
    const header_point: repository_layout.BodyPoint = .{ .col = target.col, .row = repository_source_geometry.source_path_row };

    _ = state.applyNavigation(allocator, .{ .mouse_source_header_press = header_point }, size);
    state.generation = 9;
    state.pending_generation = 9;
    var unchanged: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(allocator, &unchanged, test_body_size));
    try std.testing.expect(state.activeMouseOwner());
    try std.testing.expect(state.sourceHeaderSelected());

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_release = state.applyNavigation(failing.allocator(), .{ .mouse_owner_release = null }, size);
    defer failed_release.deinit(failing.allocator());
    try std.testing.expect(failed_release.command == null);
    try std.testing.expect(!state.activeMouseOwner());
    try std.testing.expectEqualStrings("Could not prepare file path copy", state.status.text());

    _ = state.applyNavigation(allocator, .{ .mouse_source_header_press = header_point }, size);
    state.requestReload(true);
    try std.testing.expect(!state.activeMouseOwner());

    _ = state.applyNavigation(allocator, .{ .mouse_source_header_press = header_point }, size);
    var replacement = try bundleForTest("main.zig\x00");
    var replacement_owned = true;
    defer if (replacement_owned) replacement.deinit(allocator);
    try state.replaceBundle(allocator, &replacement);
    replacement_owned = false;
    try std.testing.expect(!state.activeMouseOwner());
}

test "repository changed filter retains changed selection without document reload" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("changed.zig", .all);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "changed.zig"),
        .manifest_revision = 3,
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("changed.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document != null);
    try std.testing.expect(!state.needs_document_revalidation);

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expect(state.displayed_document != null);
}

test "repository changed filter falls back and restores owned All selection" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "clean.zig"),
        .manifest_revision = 3,
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(state.needs_document_revalidation);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
}

test "repository changed navigation and mouse use only filtered visible rows" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a-change.zig\x00b-clean.zig\x00c-change.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a-change.zig\x00 M c-change.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("a-change.zig", .all);
    state.viewer.tree_cursor = 1;
    const size = chasen.Size{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .toggle_changed_filter, size);
    try std.testing.expectEqual(@as(usize, 2), state.bundle.?.tree.visible_len);

    _ = state.applyNavigation(allocator, .move_down, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    const mouse_msg = state.mouseToMsg(.{ .col = 1, .row = 4 }, .left, size) orelse return error.ExpectedFilteredMouseRow;
    _ = state.applyNavigation(allocator, mouse_msg, size);
    try std.testing.expectEqualStrings("a-change.zig", state.selected_path.?);
    _ = state.applyNavigation(allocator, .tree_last, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    state.viewer.tree_cursor = 99;
    state.viewer.tree_vertical_scroll = 99;
    state.clampForBodySize(.{ .width = 24, .height = 2 });
    try std.testing.expect(state.viewer.tree_cursor < state.tree_projection.visibleLen(&state.bundle.?.tree));
    try std.testing.expect(state.viewer.tree_vertical_scroll < state.tree_projection.visibleLen(&state.bundle.?.tree));
}

test "repository changed no-match clears document and All restores anchor once" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, "");
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "clean.zig"),
        .manifest_revision = 3,
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expect(state.selected_path == null);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.needs_document_revalidation);
    const generation = state.document_generation;
    try std.testing.expect(!state.applyNavigation(allocator, .tree_first, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqual(generation, state.document_generation);
}

test "repository changed filter allocation failure leaves mode and selection unchanged" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .pending_document_generation = 7,
        .pending_syntax_generation = 8,
        .pending_change_map_generation = 9,
        .needs_syntax_request = true,
        .needs_change_map_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expect(!state.applyNavigation(failing.allocator(), .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expectEqual(@as(?u64, 7), state.pending_document_generation);
    try std.testing.expectEqual(@as(?u64, 8), state.pending_syntax_generation);
    try std.testing.expectEqual(@as(?u64, 9), state.pending_change_map_generation);
    try std.testing.expect(state.needs_syntax_request);
    try std.testing.expect(state.needs_change_map_request);
    try std.testing.expectEqualStrings("Could not preserve All selection", state.status.text());
}

test "repository filter discoverability defaults new identity and preserves same identity mode" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 1, .inode = 2 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;

    state.deactivate();
    state.activate(4, identity);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);

    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);

    state.deactivate();
    state.activate(4, identity);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);

    state.repositoryChanged(allocator, 5, .{ .device = 3, .inode = 4 });
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);

    var replacement = try bundleForTest("next-change.zig\x00next-clean.zig\x00");
    var replacement_owned = true;
    defer if (replacement_owned) replacement.deinit(allocator);
    try applyBundleStatusForTest(&replacement, " M next-change.zig\x00");
    try state.replaceBundle(allocator, &replacement);
    replacement_owned = false;
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqual(@as(usize, 1), state.bundle.?.tree.visible_len);
    try std.testing.expectEqualStrings("next-change.zig", state.selected_path.?);
    try std.testing.expect(state.bundle.?.tree.filePath("next-clean.zig", .changed) == null);
}

test "repository status-only completion preserves source and revisions" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
        .source_revision = 11,
        .displayed_document = .{
            .path = try allocator.dupe(u8, "a.zig"),
            .manifest_revision = 7,
            .source_revision = 11,
            .authority = .accepted,
            .value = .{ .inert = .unreadable },
        },
    };
    defer state.deinit(allocator);
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    var request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer request.deinit(allocator);
    const displayed_path_address = @intFromPtr(state.displayed_document.?.path.ptr);
    var finished = repository_tasks.ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
            allocator,
            try allocator.dupe(u8, " M a.zig\x00"),
        ) } },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished, test_body_size));
    try std.testing.expectEqual(@as(u64, 7), state.manifest_revision);
    try std.testing.expectEqual(@as(u64, 11), state.source_revision);
    try std.testing.expectEqual(displayed_path_address, @intFromPtr(state.displayed_document.?.path.ptr));
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expect(state.wantsDocumentRequest());
    try std.testing.expectEqual(repository_change_index.Kind.modified, state.bundle.?.tree.nodes[0].file_change.?);

    state.needs_revalidation = true;
    var unavailable_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer unavailable_request.deinit(allocator);
    var unavailable = repository_tasks.ManifestFinished{
        .identity = unavailable_request.identity,
        .root_identity = unavailable_request.root.identity,
        .generation = unavailable_request.generation,
        .result = .{ .status_changed = .unavailable },
    };
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &unavailable, test_body_size));
    try std.testing.expect(state.bundle.?.tree.nodes[0].file_change == null);
    try std.testing.expect(!state.bundle.?.status_available);
    try std.testing.expectEqual(@as(u64, 7), state.manifest_revision);
    try std.testing.expectEqual(displayed_path_address, @intFromPtr(state.displayed_document.?.path.ptr));
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expect(state.wantsDocumentRequest());
}

test "repository changed status loss clears projection and All restores anchor" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
        .displayed_document = .{
            .path = try allocator.dupe(u8, "a.zig"),
            .manifest_revision = 7,
            .authority = .accepted,
            .value = .{ .inert = .binary },
        },
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("a.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);

    var request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer request.deinit(allocator);
    var unavailable = repository_tasks.ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .status_changed = .unavailable },
    };
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &unavailable, test_body_size));
    try std.testing.expect(state.selected_path == null);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("a.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expect(state.needs_document_revalidation);
}

test "repository changed status refresh moves clears and repopulates selection" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00b-clean.zig\x00c.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("a.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });

    const snapshots = [_][]const u8{
        " M c.zig\x00",
        "",
        " M a.zig\x00",
    };
    const expected = [_]?[]const u8{ "c.zig", null, "a.zig" };
    for (snapshots, expected) |status_bytes, expected_path| {
        state.needs_revalidation = true;
        var request = try state.prepareRequest(allocator, root.path, &root.capability);
        defer request.deinit(allocator);
        var finished = repository_tasks.ManifestFinished{
            .identity = request.identity,
            .root_identity = request.root.identity,
            .generation = request.generation,
            .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
                allocator,
                try allocator.dupe(u8, status_bytes),
            ) } },
        };
        defer finished.deinit(allocator);
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished, test_body_size));
        if (expected_path) |path|
            try std.testing.expectEqualStrings(path, state.selected_path.?)
        else
            try std.testing.expect(state.selected_path == null);
    }
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);
}

test "repository replacement keeps changed mode anchor independent of manifest storage" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });

    var incoming = try bundleForTest("a-first.zig\x00changed.zig\x00new.zig\x00");
    errdefer incoming.deinit(allocator);
    try applyBundleStatusForTest(&incoming, " M changed.zig\x00?? new.zig\x00");
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
}

fn runRepositoryTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try process_runner.runCaptured(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer result.deinit(std.testing.allocator);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.RepositoryTestGitFailed;
}

test "repository real reload updates status color and selected source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, &parent_environment);
    defer environment.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var work = try tmp.dir.openDir(io, "repo", .{});
    defer work.close(io);
    try runRepositoryTestGit(io, work, &.{ "git", "init", "--initial-branch=main" });
    try work.writeFile(io, .{ .sub_path = "a.zig", .data = "const value = 1;\n" });
    try runRepositoryTestGit(io, work, &.{ "git", "add", "a.zig" });
    try runRepositoryTestGit(io, work, &.{
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "base",
    });
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var capability = try root_capability.RootCapability.openCanonical(root_path);
    defer capability.deinit();

    var state: RepositoryPageState = .{};
    defer state.deinit(allocator);
    state.activate(1, capability.identity);
    var initial_request = try state.prepareRequest(allocator, root_path, &capability);
    defer initial_request.deinit(allocator);
    var initial_finished = repository_tasks.ManifestFinished{
        .identity = initial_request.identity,
        .root_identity = initial_request.root.identity,
        .generation = initial_request.generation,
        .result = repository_tasks.runManifestLoad(
            initial_request.root.dir(),
            &environment,
            initial_request.expected_fingerprint,
            initial_request.expected_status_fingerprint,
            allocator,
            io,
        ),
    };
    defer initial_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &initial_finished, test_body_size));
    try std.testing.expect(state.wantsDocumentRequest());

    var initial_document_request = try state.prepareDocumentRequest(allocator, &capability);
    defer initial_document_request.deinit(allocator);
    var initial_snapshot = selected_document.load(initial_document_request.root, initial_document_request.path, allocator, io);
    defer initial_snapshot.deinit(allocator);
    var initial_document_finished = repository_tasks.DocumentFinished{
        .identity = initial_document_request.identity,
        .root_identity = initial_document_request.root.identity,
        .generation = initial_document_request.generation,
        .manifest_revision = initial_document_request.manifest_revision,
        .path = try allocator.dupe(u8, initial_document_request.path),
        .value = repository_tasks.DocumentValue.fromLoaded(allocator, &initial_snapshot.value),
        .metadata = initial_snapshot.metadata,
    };
    initial_snapshot.metadata = null;
    defer initial_document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &initial_document_finished));
    try std.testing.expectEqualStrings("const value = 1;\n", state.currentSource().?.bytes);
    const manifest_revision = state.manifest_revision;

    try work.writeFile(io, .{ .sub_path = "a.zig", .data = "const value = 2;\n" });
    state.requestReload(true);
    var reload_request = try state.prepareRequest(allocator, root_path, &capability);
    defer reload_request.deinit(allocator);
    var reload_finished = repository_tasks.ManifestFinished{
        .identity = reload_request.identity,
        .root_identity = reload_request.root.identity,
        .generation = reload_request.generation,
        .result = repository_tasks.runManifestLoad(
            reload_request.root.dir(),
            &environment,
            reload_request.expected_fingerprint,
            reload_request.expected_status_fingerprint,
            allocator,
            io,
        ),
    };
    defer reload_finished.deinit(allocator);
    try std.testing.expect(reload_finished.result == .status_changed);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &reload_finished, test_body_size));
    try std.testing.expectEqual(manifest_revision, state.manifest_revision);
    try std.testing.expectEqual(repository_change_index.Kind.modified, state.bundle.?.tree.nodes[0].file_change.?);
    try std.testing.expect(state.wantsDocumentRequest());

    var reload_document_request = try state.prepareDocumentRequest(allocator, &capability);
    defer reload_document_request.deinit(allocator);
    var reload_snapshot = selected_document.load(reload_document_request.root, reload_document_request.path, allocator, io);
    defer reload_snapshot.deinit(allocator);
    var reload_document_finished = repository_tasks.DocumentFinished{
        .identity = reload_document_request.identity,
        .root_identity = reload_document_request.root.identity,
        .generation = reload_document_request.generation,
        .manifest_revision = reload_document_request.manifest_revision,
        .path = try allocator.dupe(u8, reload_document_request.path),
        .value = repository_tasks.DocumentValue.fromLoaded(allocator, &reload_snapshot.value),
        .metadata = reload_snapshot.metadata,
    };
    reload_snapshot.metadata = null;
    defer reload_document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &reload_document_finished));
    try std.testing.expectEqualStrings("const value = 2;\n", state.currentSource().?.bytes);
}

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    capability: root_capability.RootCapability,

    fn init() !TestRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .capability = try root_capability.RootCapability.openCanonical(path),
        };
    }

    fn deinit(self: *TestRoot) void {
        self.capability.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "Repository branch terminal does not mutate the primary page status" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(3, root.capability.identity);
    state.status.set("Selected source copied", .{});

    var request = try state.prepareBranchRequest(
        std.testing.allocator,
        root.path,
        &root.capability,
    );
    defer request.deinit(std.testing.allocator);
    var finished = repository_branch.Finished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .failed = .load_failed },
    };
    defer finished.deinit();

    try std.testing.expectEqual(repository_branch.ApplyOutcome.failed, state.applyBranchFinished(std.testing.allocator, &finished));
    try std.testing.expectEqualStrings("Selected source copied", state.status.text());
}

test "Repository path history projects accepted fact independently from document state" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.path_history.invalidate(allocator, true);
    var request = try state.preparePathHistoryRequest(allocator, root.path, &root.capability);
    defer request.deinit(allocator);
    var finished = repository_path_history.Finished{
        .identity = request.identity,
        .root_identity = request.root_identity,
        .manifest_revision = request.manifest_revision,
        .generation = request.generation,
        .path = request.path,
        .outcome = .{ .known = .{
            .head = .{ .oid = try allocator.dupe(u8, "0123456789abcdef0123456789abcdef01234567") },
            .fact = .{ .committed = 951_827_640 },
        } },
    };
    request.path = &.{};
    defer finished.deinit(allocator);

    try std.testing.expectEqual(
        repository_path_history.ApplyOutcome.known,
        state.applyPathHistoryFinished(allocator, &finished),
    );
    const presentation = state.sourceHeaderPresentation().?;
    try std.testing.expectEqual(@as(i64, 951_827_640), presentation.commit_fact.committed);
    try std.testing.expect(presentation.line_position == null);
}

test "Repository path history rejects present and unborn basis mismatches in both completion orders" {
    const allocator = std.testing.allocator;
    const Basis = enum { present, unborn };
    const present_oid = "0123456789abcdef0123456789abcdef01234567";
    const cases = [_]struct {
        history: Basis,
        branch: Basis,
        branch_first: bool,
    }{
        .{ .history = .present, .branch = .unborn, .branch_first = true },
        .{ .history = .present, .branch = .unborn, .branch_first = false },
        .{ .history = .unborn, .branch = .present, .branch_first = true },
        .{ .history = .unborn, .branch = .present, .branch_first = false },
    };

    for (cases) |case| {
        var root = try TestRoot.init();
        defer root.deinit();
        var state: RepositoryPageState = .{
            .active = true,
            .activation_id = 2,
            .repo_epoch = 3,
            .root_identity = root.capability.identity,
            .bundle = try bundleForTest("main.zig\x00"),
            .load_state = .loaded,
            .manifest_revision = 7,
        };
        defer state.deinit(allocator);
        state.selected_path = state.bundle.?.tree.firstFilePath();

        var branch_request = try state.prepareBranchRequest(allocator, root.path, &root.capability);
        defer branch_request.deinit(allocator);
        state.path_history.invalidate(allocator, true);
        var history_request = try state.preparePathHistoryRequest(allocator, root.path, &root.capability);
        defer history_request.deinit(allocator);

        var branch_builder = git_branch_status.Builder.init(allocator);
        errdefer branch_builder.deinit();
        try branch_builder.setBranchHead("main");
        if (case.branch == .present) try branch_builder.setOid(present_oid);
        var branch_finished = repository_branch.Finished{
            .identity = branch_request.identity,
            .root_identity = branch_request.root.identity,
            .generation = branch_request.generation,
            .result = .{ .loaded = branch_builder.finish() },
        };
        defer branch_finished.deinit();

        const history_outcome: git_read.RepositoryPathHistoryOutcome = switch (case.history) {
            .present => .{ .known = .{
                .head = .{ .oid = try allocator.dupe(u8, present_oid) },
                .fact = .{ .committed = 42 },
            } },
            .unborn => .{ .known = .{ .head = .unborn, .fact = .uncommitted } },
        };
        var history_finished = repository_path_history.Finished{
            .identity = history_request.identity,
            .root_identity = history_request.root_identity,
            .manifest_revision = history_request.manifest_revision,
            .generation = history_request.generation,
            .path = history_request.path,
            .outcome = history_outcome,
        };
        history_request.path = &.{};
        defer history_finished.deinit(allocator);

        if (case.branch_first) {
            _ = state.applyBranchFinished(allocator, &branch_finished);
            try std.testing.expectEqual(
                repository_path_history.ApplyOutcome.unavailable,
                state.applyPathHistoryFinished(allocator, &history_finished),
            );
            try std.testing.expect(!state.path_history.needs_revalidation);
        } else {
            try std.testing.expectEqual(
                repository_path_history.ApplyOutcome.known,
                state.applyPathHistoryFinished(allocator, &history_finished),
            );
            _ = state.applyBranchFinished(allocator, &branch_finished);
            try std.testing.expect(state.path_history.needs_revalidation);
        }

        try std.testing.expect(state.path_history.accepted == null);
        try std.testing.expect(state.path_history.terminal == .unavailable);
        try std.testing.expect(state.sourceHeaderPresentation().?.commit_fact == .unavailable);
    }
}

test "Repository path history schedules only selection reload and reactivation edges" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("a.zig\x00b.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    state.path_history.needs_revalidation = false;
    state.viewer.focus = .source;

    const generation = state.path_history.generation;
    const cursor_update = state.applyNavigation(allocator, .move_down, .{ .width = 80, .height = 12 });
    try std.testing.expect(!cursor_update.selected_path_changed);
    try std.testing.expectEqual(generation, state.path_history.generation);
    try std.testing.expect(!state.path_history.needs_revalidation);

    state.viewer.focus = .tree;
    const selection_update = state.applyNavigation(allocator, .move_down, .{ .width = 80, .height = 12 });
    try std.testing.expect(selection_update.selected_path_changed);
    try std.testing.expectEqualStrings("b.zig", state.selected_path.?);
    try std.testing.expect(state.path_history.needs_revalidation);

    state.requestReload(true);
    try std.testing.expect(!state.path_history.needs_revalidation);
    try std.testing.expect(state.path_history.terminal == .unavailable);
    state.deactivate();
    state.activate(state.repo_epoch, state.root_identity);
    try std.testing.expect(state.path_history.needs_revalidation);
}

test "repository syntax task is plain-first and accepts only matching source identity" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    var root = try TestRoot.init();
    defer root.deinit();
    const source_bytes = "const value: usize = 42;\n";
    try root.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = source_bytes });
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_syntax_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .authority = .accepted,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
    };
    try std.testing.expectEqual(@as(usize, 0), state.displayed_document.?.syntax_spans.spans.len);

    var request = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    var accepted_candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    var accepted = repository_tasks.SyntaxFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = request.expected_fingerprint,
        .result = .{ .loaded = try source_syntax.build(allocator, state.currentSource().?, &accepted_candidates) },
    };
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &accepted));
    try std.testing.expect(state.pending_syntax_generation == null);
    try std.testing.expect(state.displayed_document.?.syntax_spans.spans.len > 0);

    var stale = repository_tasks.SyntaxFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = .init("different"),
        .result = .{ .loaded = .empty() },
    };
    defer stale.deinit(allocator);

    stale.identity.repo_epoch += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.identity = request.identity;

    stale.identity.activation_id += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.identity = request.identity;

    stale.manifest_revision += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.manifest_revision = request.manifest_revision;

    stale.source_revision += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.source_revision = request.source_revision;

    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, "other.zig");
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, request.path);

    var other_root = try TestRoot.init();
    defer other_root.deinit();
    stale.root_identity = other_root.capability.identity;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.root_identity = request.root.identity;

    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));

    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    const undelivered_spans = try source_syntax.build(allocator, state.currentSource().?, &candidates);
    var undelivered = Msg{ .syntax_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = request.expected_fingerprint,
        .result = .{ .loaded = undelivered_spans },
    } };
    undelivered.deinitUndelivered(allocator);
}

test "repository change decoration accepts only the exact displayed source identity" {
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const source_bytes = "one\ntwo\n";
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_change_map_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .authority = .accepted,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
        .change_decoration = .eligible,
    };

    var request = try state.prepareChangeMapRequest(allocator, &root.capability, "/tmp");
    defer request.deinit(allocator);
    var finished = repository_tasks.ChangeMapFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = request.expected_fingerprint,
        .content_line_count = request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &finished));
    try std.testing.expectEqual(repository_change_map.Kind.added, state.displayed_document.?.change_decoration.map().?.row(1));

    state.displayed_document.?.change_decoration.deinit(allocator);
    state.displayed_document.?.change_decoration = .eligible;
    state.needs_change_map_request = true;
    var stale_request = try state.prepareChangeMapRequest(allocator, &root.capability, "/tmp");
    defer stale_request.deinit(allocator);
    var stale = repository_tasks.ChangeMapFinished{
        .identity = stale_request.identity,
        .root_identity = stale_request.root.identity,
        .generation = stale_request.generation,
        .manifest_revision = stale_request.manifest_revision,
        .source_revision = stale_request.source_revision,
        .path = try allocator.dupe(u8, stale_request.path),
        .fingerprint = stale_request.expected_fingerprint,
        .content_line_count = stale_request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    };
    defer stale.deinit(allocator);

    stale.identity.repo_epoch += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.identity = stale_request.identity;

    stale.identity.activation_id += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.identity = stale_request.identity;

    stale.generation += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.generation = stale_request.generation;

    stale.manifest_revision += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.manifest_revision = stale_request.manifest_revision;

    var other_root = try TestRoot.init();
    defer other_root.deinit();
    stale.root_identity = other_root.capability.identity;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.root_identity = stale_request.root.identity;

    stale.source_revision += 1;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.source_revision = stale_request.source_revision;

    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, "other.zig");
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, stale_request.path);

    stale.content_line_count += 1;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    try std.testing.expect(state.needs_document_revalidation);
    stale.content_line_count = stale_request.expected_content_line_count;
    state.needs_document_revalidation = false;

    stale.fingerprint = .init("newer source");
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    try std.testing.expect(state.displayed_document.?.change_decoration.isEligible());
    try std.testing.expect(state.needs_document_revalidation);

    var undelivered = Msg{ .change_map_finished = .{
        .identity = stale_request.identity,
        .root_identity = stale_request.root.identity,
        .generation = stale_request.generation,
        .manifest_revision = stale_request.manifest_revision,
        .source_revision = stale_request.source_revision,
        .path = try allocator.dupe(u8, stale_request.path),
        .fingerprint = stale_request.expected_fingerprint,
        .content_line_count = stale_request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    } };
    undelivered.deinitUndelivered(allocator);
}

fn expectRepositoryDecorationCompletionOrder(map_first: bool) !void {
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const source_bytes = "const value = 1;\n";
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .syntax_generation = 7,
        .pending_syntax_generation = 7,
        .change_map_generation = 8,
        .pending_change_map_generation = 8,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .authority = .accepted,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
        .change_decoration = .eligible,
    };
    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    var syntax_finished = repository_tasks.SyntaxFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .root_identity = root.capability.identity,
        .generation = 7,
        .manifest_revision = 5,
        .source_revision = 6,
        .path = try allocator.dupe(u8, "main.zig"),
        .fingerprint = state.currentSource().?.fingerprint,
        .result = .{ .loaded = try source_syntax.build(allocator, state.currentSource().?, &candidates) },
    };
    defer syntax_finished.deinit(allocator);
    var map_finished = repository_tasks.ChangeMapFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .root_identity = root.capability.identity,
        .generation = 8,
        .manifest_revision = 5,
        .source_revision = 6,
        .path = try allocator.dupe(u8, "main.zig"),
        .fingerprint = state.currentSource().?.fingerprint,
        .content_line_count = 1,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 1) },
    };
    defer map_finished.deinit(allocator);

    if (map_first) {
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &map_finished));
        try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &syntax_finished));
    } else {
        try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &syntax_finished));
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &map_finished));
    }
    try std.testing.expectEqual(repository_change_map.Kind.added, state.displayed_document.?.change_decoration.map().?.row(0));
    try std.testing.expectEqual(@as(usize, 1), state.displayed_document.?.syntax_spans.spans.len);
}

test "repository syntax and change map completions are order independent" {
    try expectRepositoryDecorationCompletionOrder(true);
    try expectRepositoryDecorationCompletionOrder(false);
}

test "repository page accepts active and inactive matching manifest completions" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(7, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = repository_tasks.ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("src/main.zig\x00") },
    };
    defer finished.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &finished, test_body_size));
    try std.testing.expectEqualStrings("src/main.zig", state.selected_path.?);
    try std.testing.expect(state.freshness == .fresh);

    state.needs_revalidation = true;
    var unchanged_request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer unchanged_request.deinit(std.testing.allocator);
    const retained_bundle = &state.bundle.?;
    var unchanged = repository_tasks.ManifestFinished{
        .identity = unchanged_request.identity,
        .root_identity = unchanged_request.root.identity,
        .generation = unchanged_request.generation,
        .result = .{ .unchanged = retained_bundle.document.fingerprint },
    };
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(std.testing.allocator, &unchanged, test_body_size));
    try std.testing.expectEqual(retained_bundle, &state.bundle.?);

    state.needs_revalidation = true;
    var inactive_request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer inactive_request.deinit(std.testing.allocator);
    state.deactivate();
    var inactive = repository_tasks.ManifestFinished{
        .identity = inactive_request.identity,
        .root_identity = inactive_request.root.identity,
        .generation = inactive_request.generation,
        .result = .{ .loaded = try bundleForTest("README.md\x00src/main.zig\x00") },
    };
    defer inactive.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &inactive, test_body_size));
    try std.testing.expect(state.bundle != null);
    try std.testing.expect(state.freshness == .validating);
    state.activate(7, root.capability.identity);
    try std.testing.expect(state.needs_revalidation);
}

test "repository page rejects stale completion and undelivered message frees payload" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(2, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var stale = repository_tasks.ManifestFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 1, .activation_id = request.identity.activation_id },
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("old.zig\x00") },
    };
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(std.testing.allocator, &stale, test_body_size));
    try std.testing.expect(state.bundle == null);

    var undelivered = Msg{ .manifest_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("owned.zig\x00") },
    } };
    undelivered.deinitUndelivered(std.testing.allocator);
}

test "repository page rejects matching generation with wrong root identity" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(2, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = repository_tasks.ManifestFinished{
        .identity = request.identity,
        .root_identity = .{ .device = request.root.identity.device, .inode = request.root.identity.inode +% 1 },
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("wrong.zig\x00") },
    };
    defer finished.deinit(std.testing.allocator);

    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(std.testing.allocator, &finished, test_body_size));
    try std.testing.expect(state.bundle == null);
    try std.testing.expectEqual(@as(u64, 0), state.manifest_revision);
    try std.testing.expect(!state.needs_document_revalidation);
}

test "repository syntax start failures preserve retryable source intent" {
    if (!source_syntax_runtime.enabled) {
        var state: RepositoryPageState = .{};
        defer state.deinit(std.testing.allocator);
        var invalid_root = root_capability.RootCapability{
            .handle = -1,
            .identity = .{ .device = 1, .inode = 2 },
        };
        try std.testing.expectError(
            error.SyntaxProviderDisabled,
            state.prepareSyntaxRequest(std.testing.allocator, &invalid_root),
        );
        return error.SkipZigTest;
    }
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value = 1;\n");
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_syntax_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .authority = .accepted,
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };

    var path_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.prepareSyntaxRequest(path_failing.allocator(), &root.capability));
    state.markSyntaxRequestPreparationFailed();
    try std.testing.expect(state.wantsSyntaxRequest());

    var invalid_root = root_capability.RootCapability{
        .handle = -1,
        .identity = root.capability.identity,
    };
    try std.testing.expectError(error.InvalidRootCapability, state.prepareSyntaxRequest(allocator, &invalid_root));
    state.markSyntaxRequestPreparationFailed();
    try std.testing.expect(state.wantsSyntaxRequest());

    // Both task allocation failure and runtime spawn rejection terminate through
    // rejectSyntaxSpawn; the still-owned request is released by its caller.
    var allocation_request = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer allocation_request.deinit(allocator);
    state.rejectSyntaxSpawn(allocation_request.generation);
    try std.testing.expect(state.wantsSyntaxRequest());

    var retry = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer retry.deinit(allocator);
    var finished = repository_tasks.SyntaxFinished{
        .identity = retry.identity,
        .root_identity = retry.root.identity,
        .generation = retry.generation,
        .manifest_revision = retry.manifest_revision,
        .source_revision = retry.source_revision,
        .path = try allocator.dupe(u8, retry.path),
        .fingerprint = retry.expected_fingerprint,
        .result = .{ .loaded = .empty() },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &finished));
    try std.testing.expect(!state.wantsSyntaxRequest());
}

test "repository page owns source focus navigation search and mouse geometry" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("src/main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const bytes = try allocator.dupe(u8, "first\nneedle here\nthird\nfourth\n");
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .authority = .accepted,
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };

    const size = chasen.Size{ .width = 60, .height = 6 };
    _ = state.applyNavigation(allocator, .toggle_focus, size);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    _ = state.applyNavigation(allocator, .move_down, size);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    _ = state.applyNavigation(allocator, .source_last, size);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
    _ = state.applyNavigation(allocator, .source_first, size);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);

    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("needle") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expect(state.source_search.match != null);

    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    try std.testing.expectEqual(Msg.focus_source, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row - 1 }, .left, size).?);
    try std.testing.expectEqual(
        Msg{ .mouse_source_press = .{ .col = 0, .row = geometry.body_first_row } },
        state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row }, .left, size).?,
    );
    try std.testing.expectEqual(Msg.mouse_source_wheel_down, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row }, .wheel_down, size).?);

    state.viewer.focus = .source;
    state.viewer.source_cursor = 2;
    _ = state.applyNavigation(allocator, .wheel_down, size);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.source_cursor);

    state.viewer.source_cursor = 99;
    state.viewer.source_vertical_scroll = 99;
    state.viewer.source_horizontal_scroll = 99;
    state.clampForBodySize(size);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_horizontal_scroll);
}

test "repository source comfort page routes wheel page search boundaries and mouse authority" {
    const allocator = std.testing.allocator;
    const content =
        "row 00\n" ++
        "row 01\n" ++
        "row 02\n" ++
        "row 03\n" ++
        "row 04\n" ++
        "row 05\n" ++
        "row 06\n" ++
        "row 07\n" ++
        "row 08\n" ++
        "row 09\n" ++
        "row 10\n" ++
        "row 11\n" ++
        "needle target\n" ++
        "row 13\n" ++
        "row 14\n" ++
        "row 15\n" ++
        "row 16\n" ++
        "row 17\n" ++
        "row 18\n" ++
        "row 19\n";
    var state = try selectionStateForTest("main.zig\x00", content);
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    try std.testing.expectEqual(@as(u16, 4), geometry.visible_source_rows);

    state.viewer.focus = .source;
    state.viewer.source_cursor = 5;
    state.viewer.source_vertical_scroll = 5;
    _ = state.applyNavigation(allocator, .mouse_source_wheel_down, size);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 6), state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 8), state.viewer.source_cursor);

    _ = state.applyNavigation(allocator, .wheel_down, size);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 6), state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 8), state.viewer.source_cursor);

    state.viewer.focus = .source;
    state.viewer.source_cursor = 5;
    state.viewer.source_vertical_scroll = 5;
    _ = state.applyNavigation(allocator, .page_down, size);
    try std.testing.expectEqual(@as(usize, 9), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.source_vertical_scroll);

    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("needle") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expectEqual(@as(usize, 12), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 10), state.viewer.source_vertical_scroll);

    _ = state.applyNavigation(allocator, .source_first, size);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
    _ = state.applyNavigation(allocator, .source_last, size);
    try std.testing.expectEqual(@as(usize, 19), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 16), state.viewer.source_vertical_scroll);

    state.viewer.source_cursor = 8;
    state.viewer.source_vertical_scroll = 5;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    try std.testing.expectEqual(@as(usize, 5), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 5), state.viewer.source_vertical_scroll);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row + 3,
    } }, size);
    try std.testing.expectEqual(@as(usize, 8), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 5), state.viewer.source_vertical_scroll);
}

test "repository drag auto-scroll validates token and steps one projected row" {
    const allocator = std.testing.allocator;
    const content =
        "row 00\n" ++ "row 01\n" ++ "row 02\n" ++ "row 03\n" ++ "row 04\n" ++
        "row 05\n" ++ "row 06\n" ++ "row 07\n" ++ "row 08\n" ++ "a\t界z\n" ++
        "row 10\n" ++ "row 11\n" ++ "row 12\n" ++ "row 13\n" ++ "row 14\n" ++
        "row 15\n" ++ "row 16\n" ++ "row 17\n" ++ "row 18\n" ++ "row 19\n";
    var state = try selectionStateForTest("main.zig\x00", content);
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    state.viewer.source_vertical_scroll = 5;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    try std.testing.expect(state.activeMouseSourceRange());
    const token_before = state.selection_owner.activeSource().?.token;
    try std.testing.expect(state.selection_owner.activeSource().?.mode == .character);
    const viewport = state.sourceAutoScrollViewport(size) orelse return error.ExpectedSourceViewport;
    const layout = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(layout.source_col, viewport.first_col);
    try std.testing.expectEqual(geometry.body_first_row, viewport.first_row);
    try std.testing.expectEqual(size.height - 1, viewport.last_row);

    var update = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
        .direction = .down,
        .endpoint = .{ .col = geometry.text_col + 5, .row = viewport.last_row },
    } }, size);
    defer update.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, update.auto_scroll.?);
    try std.testing.expectEqual(@as(usize, 6), state.viewer.source_vertical_scroll);
    const live = state.selection_owner.activeSource().?;
    try std.testing.expect(live.token.eql(token_before));
    try std.testing.expect(live.mode == .character);
    try std.testing.expectEqual(@as(usize, 9), live.focus.line_index);
    try std.testing.expectEqual(@as(usize, 2), live.focus.leading_byte);
    try std.testing.expectEqual(@as(usize, 5), live.focus.trailing_byte);

    // The same live token and character mode continue through repeated steps
    // beyond the original viewport. The completed bytes include the TAB and
    // wide glyph traversed by the first tick, but stop at the exact terminal
    // cell resolved by the last one.
    for (0..2) |_| {
        var repeated = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
            .direction = .down,
            .endpoint = .{ .col = geometry.text_col + 5, .row = viewport.last_row },
        } }, size);
        defer repeated.deinit(allocator);
        try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, repeated.auto_scroll.?);
    }
    const character_live = state.selection_owner.activeSource().?;
    try std.testing.expect(character_live.token.eql(token_before));
    try std.testing.expect(character_live.mode == .character);
    try std.testing.expectEqual(@as(usize, 11), character_live.focus.line_index);
    var character_release = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer character_release.deinit(allocator);
    const expected_character = "row 05\nrow 06\nrow 07\nrow 08\na\t界z\nrow 10\nrow 11";
    try std.testing.expectEqualStrings(expected_character, state.completed_selection.?.text);
    var character_copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer character_copy.deinit(allocator);
    var character_command = character_copy.takeCommand() orelse return error.ExpectedSourceCopyCommand;
    defer character_command.deinit(allocator);
    switch (character_command) {
        .copy_source_selection => |text| try std.testing.expectEqualStrings(expected_character, text),
        else => return error.ExpectedSourceCopyCommand,
    }

    // A retained #78 action row becomes the top edge row during a new line
    // drag. It advances the viewport without replacing the semantic endpoint;
    // subsequent repeated steps finish off-screen and Copy contains source
    // lines only, never the virtual action label.
    try installFirstLineCandidateForTest(&state, allocator);
    state.viewer.source_vertical_scroll = 0;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.gutter_col,
        .row = viewport.first_row,
    } }, size);
    const line_token = state.selection_owner.activeSource().?.token;
    try std.testing.expect(state.selection_owner.activeSource().?.mode == .line);
    state.viewer.source_vertical_scroll = 2;
    const focus_before_action = state.selection_owner.activeSource().?.focus;
    var action_row = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = geometry.text_col, .row = viewport.first_row },
    } }, size);
    defer action_row.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, action_row.auto_scroll.?);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);
    try std.testing.expect(std.meta.eql(focus_before_action, state.selection_owner.activeSource().?.focus));

    for (0..3) |_| {
        var repeated = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
            .direction = .down,
            .endpoint = .{ .col = geometry.gutter_col, .row = viewport.last_row },
        } }, size);
        defer repeated.deinit(allocator);
        try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, repeated.auto_scroll.?);
    }
    const line_live = state.selection_owner.activeSource().?;
    try std.testing.expect(line_live.token.eql(line_token));
    try std.testing.expect(line_live.mode == .line);
    try std.testing.expectEqual(@as(usize, 5), line_live.focus.line_index);
    var line_release = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer line_release.deinit(allocator);
    const expected_lines = "row 00\nrow 01\nrow 02\nrow 03\nrow 04\nrow 05\n";
    try std.testing.expectEqualStrings(expected_lines, state.completed_selection.?.text);
    try std.testing.expect(std.mem.indexOf(u8, state.completed_selection.?.text, selection_action.controls_text) == null);
    var line_copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer line_copy.deinit(allocator);
    var line_command = line_copy.takeCommand() orelse return error.ExpectedSourceCopyCommand;
    defer line_command.deinit(allocator);
    switch (line_command) {
        .copy_source_selection => |text| {
            try std.testing.expectEqualStrings(expected_lines, text);
            try std.testing.expect(std.mem.indexOf(u8, text, selection_action.controls_text) == null);
        },
        else => return error.ExpectedSourceCopyCommand,
    }

    state.viewer.source_vertical_scroll = 0;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = viewport.first_row,
    } }, size);
    state.viewer.source_vertical_scroll = state.selectionActionProjection().?.maxScroll(geometry.visible_source_rows);
    var edge = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
        .direction = .down,
        .endpoint = .{ .col = geometry.text_col, .row = viewport.last_row },
    } }, size);
    defer edge.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.content_edge, edge.auto_scroll.?);
    try std.testing.expect(state.activeMouseSourceRange());

    state.repo_epoch += 1;
    var stale = state.applyNavigation(allocator, .{ .mouse_source_auto_scroll_step = .{
        .direction = .up,
        .endpoint = .{ .col = geometry.text_col, .row = viewport.first_row },
    } }, size);
    defer stale.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.stale_owner, stale.auto_scroll.?);
    try std.testing.expect(!state.activeMouseOwner());
}

test "repository selection live gesture fixes mode and resumes after leaving the pane" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\nthird\nfourth\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const document = state.currentSource().?;
    const geometry = state.sourceGeometry(size, document);
    const first_row = geometry.body_first_row;

    state.source_search.mode = true;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    state.source_search.mode = false;
    state.file_search.mode = true;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    state.file_search.mode = false;

    // Separators are focus-only dead space and never create a selection.
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.separator_col.?, .row = first_row } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 3, .row = first_row } }, size);
    try std.testing.expect(state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() != null);
    try std.testing.expectEqual(repository_selection.Mode.character, state.selection_owner.activeSource().?.mode);
    try std.testing.expectEqual(@as(usize, 3), state.selection_owner.activeSource().?.anchor.leading_byte);
    try std.testing.expectEqual(@as(usize, 4), state.selection_owner.activeSource().?.anchor.trailing_byte);

    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = null }, size);
    try std.testing.expect(!state.selection_owner.activeSource().?.moved);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{ .col = geometry.text_col + 4, .row = first_row + 1 } }, size);
    try std.testing.expect(state.selection_owner.activeSource().?.moved);
    try std.testing.expectEqual(@as(usize, 1), state.selection_owner.activeSource().?.focus.line_index);
    try std.testing.expectEqual(@as(usize, 5), state.selection_owner.activeSource().?.focus.trailing_byte);
    try std.testing.expectEqual(repository_selection.Mode.character, state.selection_owner.activeSource().?.mode);

    // A character drag entering its own gutter clamps to the leading logical
    // boundary; it does not switch to whole-line mode.
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{ .col = geometry.gutter_col, .row = first_row + 1 } }, size);
    try std.testing.expectEqual(repository_selection.Mode.character, state.selection_owner.activeSource().?.mode);
    try std.testing.expectEqual(@as(usize, 0), state.selection_owner.activeSource().?.focus.leading_byte);
    try std.testing.expectEqual(@as(usize, 0), state.selection_owner.activeSource().?.focus.trailing_byte);
    var character_release = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer character_release.deinit(allocator);
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() == null);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.gutter_col, .row = first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.selection_owner.activeSource().?.mode);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{ .col = geometry.text_col + 2, .row = first_row + 1 } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.selection_owner.activeSource().?.mode);
    try std.testing.expectEqual(@as(usize, 1), state.selection_owner.activeSource().?.focus.line_index);
    var line_release = state.applyNavigation(allocator, .{ .mouse_owner_release = .{ .col = geometry.text_col + 2, .row = first_row + 1 } }, size);
    defer line_release.deinit(allocator);
    try std.testing.expect(!state.activeMouseSourceRange());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.line_number_col, .row = first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.selection_owner.activeSource().?.mode);
    state.cancelMouseOwner();
}

test "repository selection hit testing applies scroll once and follows line number geometry" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\nthird\nfourth\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const document = state.currentSource().?;
    var geometry = state.sourceGeometry(size, document);
    const first_row = geometry.body_first_row;

    state.viewer.source_horizontal_scroll = 2;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 1, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, 3), state.selection_owner.activeSource().?.anchor.leading_byte);
    state.cancelMouseOwner();

    state.viewer.source_horizontal_scroll = 0;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 20, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, "ABCDEFG".len), state.selection_owner.activeSource().?.anchor.leading_byte);
    try std.testing.expectEqual(@as(usize, "ABCDEFG".len), state.selection_owner.activeSource().?.anchor.trailing_byte);
    state.cancelMouseOwner();

    state.viewer.source_vertical_scroll = 1;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, 1), state.selection_owner.activeSource().?.anchor.line_index);
    state.cancelMouseOwner();

    state.viewer.source_vertical_scroll = 0;
    state.viewer.source_horizontal_scroll = 0;
    _ = state.applyNavigation(allocator, .toggle_line_numbers, size);
    geometry = state.sourceGeometry(size, document);
    try std.testing.expectEqual(@as(u16, 1), geometry.text_col);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.character, state.selection_owner.activeSource().?.mode);
    try std.testing.expectEqual(@as(usize, 0), state.selection_owner.activeSource().?.anchor.leading_byte);

    var atomic = try selectionStateForTest("unicode.zig\x00", "a\t界e\u{301}👩‍💻z\n");
    defer atomic.deinit(allocator);
    const atomic_document = atomic.currentSource().?;
    const atomic_geometry = atomic.sourceGeometry(size, atomic_document);
    atomic.viewer.source_horizontal_scroll = 2;
    const occupied = [_]struct {
        viewport_cell: usize,
        byte_start: usize,
        byte_end: usize,
    }{
        .{ .viewport_cell = 0, .byte_start = 1, .byte_end = 2 },
        .{ .viewport_cell = 1, .byte_start = 1, .byte_end = 2 },
        .{ .viewport_cell = 2, .byte_start = 2, .byte_end = 5 },
        .{ .viewport_cell = 3, .byte_start = 2, .byte_end = 5 },
        .{ .viewport_cell = 4, .byte_start = 5, .byte_end = 8 },
        .{ .viewport_cell = 5, .byte_start = 8, .byte_end = 19 },
        .{ .viewport_cell = 6, .byte_start = 8, .byte_end = 19 },
    };
    for (occupied) |case| {
        _ = atomic.applyNavigation(allocator, .{ .mouse_source_press = .{
            .col = atomic_geometry.text_col + @as(u16, @intCast(case.viewport_cell)),
            .row = atomic_geometry.body_first_row,
        } }, size);
        const anchor = atomic.selection_owner.activeSource().?.anchor;
        try std.testing.expectEqual(case.byte_start, anchor.leading_byte);
        try std.testing.expectEqual(case.byte_end, anchor.trailing_byte);
        atomic.cancelMouseOwner();
    }

    const saturated = RepositoryPageState.pointAtTextCell(atomic_document, 0, std.math.maxInt(usize), 1).?;
    try std.testing.expectEqual(@as(usize, "a\t界e\u{301}👩‍💻z".len), saturated.leading_byte);
    try std.testing.expectEqual(saturated.leading_byte, saturated.trailing_byte);
}

test "repository selection synthetic empty row rejects every gesture stage" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("empty.zig\x00", "");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .begin_keyboard_line_selection, size);
    try std.testing.expect(!state.activeKeyboardLineSelection());
    try std.testing.expectEqualStrings("No source line is available for selection", state.status.text());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.gutter_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    var release = state.applyNavigation(allocator, .{ .mouse_owner_release = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    defer release.deinit(allocator);
    try std.testing.expect(!state.activeMouseSourceRange());
}

test "repository selection owner replacement cancels live borrowed selection first" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("a.zig\x00b.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() != null);
    state.viewer.focus = .tree;
    try std.testing.expect(state.applyNavigation(allocator, .move_down, size).selected_path_changed);
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.displayed_document == null);

    state.repositoryChanged(allocator, 9, .{ .device = 10, .inode = 11 });
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.bundle == null);
}

test "repository selection accepted manifest and document replacement cancel live borrow" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeMouseSourceRange());
    var incoming = try bundleForTest("main.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() == null);

    geometry = state.sourceGeometry(size, state.currentSource().?);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() != null);
    state.document_generation = 8;
    state.pending_document_generation = 8;
    // Byte-identical content still arrives in separately owned storage. The
    // active owner cancels before replacement rather than borrowing across that swap.
    const replacement_bytes = try allocator.dupe(u8, "old source\n");
    var replacement: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .source = try source_document.Document.initOwned(allocator, replacement_bytes, .init(replacement_bytes)) },
    };
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &replacement));
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.liveSourceSelection() == null);
    try std.testing.expectEqualStrings("old source", state.currentSource().?.lineBody(0).?);
}

test "repository selection moved release installs candidate and explicit copy command" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col + 3,
        .row = geometry.body_first_row,
    } }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{
        .col = geometry.text_col + 4,
        .row = geometry.body_first_row + 1,
    } }, size);
    var update = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer update.deinit(allocator);
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
    try std.testing.expect(update.command == null);

    var copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer copy.deinit(allocator);
    var command = copy.takeCommand() orelse return error.ExpectedSourceCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_source_selection => |text| {
            try std.testing.expectEqualStrings("DEFG\nHIJKL", text);
            text[0] = 'X';
            try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
        },
        else => return error.ExpectedSourceCopyCommand,
    }

    // A later click changes cursor/focus only and retains the accepted owner.
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    var click = state.applyNavigation(allocator, .{ .mouse_owner_release = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    defer click.deinit(allocator);
    try std.testing.expect(click.command == null);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
}

test "repository selection actions share wide narrow render geometry and dispatch" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\nthree\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);

    const wide: chasen.Size = .{ .width = 80, .height = 8 };
    const wide_layout = repository_layout.bodyLayout(wide, state.viewer.tree_width, state.viewer.tree_hidden);
    const geometry = state.sourceGeometry(wide, state.currentSource().?);
    const controls_row = geometry.body_first_row + 2;
    try std.testing.expect(state.mouseToMsg(.{
        .col = wide_layout.source_col,
        .row = geometry.body_first_row + 1,
    }, .left, wide) == null);
    try std.testing.expect(state.mouseToMsg(.{
        .col = wide_layout.source_col + 8,
        .row = controls_row,
    }, .left, wide) == null);
    try std.testing.expectEqual(
        Msg{ .selection_action = .copy },
        state.mouseToMsg(.{ .col = wide_layout.source_col, .row = controls_row }, .left, wide).?,
    );
    try std.testing.expectEqual(
        Msg{ .selection_action = .clear },
        state.mouseToMsg(.{ .col = wide_layout.source_col + 9, .row = controls_row }, .left, wide).?,
    );
    try std.testing.expect(!state.activeMouseSourceRange());

    var copied = state.applyNavigation(allocator, .{ .selection_action = .copy }, wide);
    defer copied.deinit(allocator);
    try std.testing.expect(copied.command != null);
    try std.testing.expect(state.completed_selection != null);

    state.viewer.tree_hidden = true;
    const narrow: chasen.Size = .{ .width = 10, .height = 6 };
    try std.testing.expectEqual(
        Msg{ .selection_action = .copy },
        state.mouseToMsg(.{ .col = 0, .row = controls_row }, .left, narrow).?,
    );
    try std.testing.expect(state.mouseToMsg(.{ .col = 9, .row = controls_row }, .left, narrow) == null);
    try std.testing.expectEqual(
        Msg{ .selection_action = .clear },
        repository_input.keyToMsg(Msg, state.inputContext(.{}), .{ .codepoint = chasen.Key.escape }).?,
    );

    state.viewer.source_vertical_scroll = 1;
    var cleared = state.applyNavigation(allocator, .{ .selection_action = .clear }, narrow);
    defer cleared.deinit(allocator);
    try std.testing.expect(cleared.command == null);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
}

test "repository selection copy authority mismatch clears without command" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.completed_selection.?.token.repo_epoch +%= 1;

    var copy = state.applyNavigation(
        allocator,
        .{ .selection_action = .copy },
        .{ .width = 60, .height = 6 },
    );
    defer copy.deinit(allocator);
    try std.testing.expect(copy.command == null);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expectEqualStrings("Source selection is no longer current", state.status.text());
}

test "repository selection resize restores semantic presentation anchor" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\nthree\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.viewer.source_vertical_scroll = 1;
    const anchor = state.captureSelectionViewportAnchor() orelse return error.ExpectedSelectionViewportAnchor;

    state.restoreSelectionViewportAnchor(anchor, .{ .width = 40, .height = 4 });
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);
    state.restoreSelectionViewportAnchor(anchor, .{ .width = 120, .height = 32 });
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
    try std.testing.expect(state.completed_selection != null);
}

test "repository selection first token to gutter keeps the token" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABC\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    try std.testing.expectEqualStrings("ABC", state.completed_selection.?.text);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_owner_drag = .{
        .col = geometry.gutter_col,
        .row = geometry.body_first_row,
    } }, size);
    var update = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, size);
    defer update.deinit(allocator);
    try std.testing.expectEqualStrings("A", state.completed_selection.?.text);
    try std.testing.expect(update.command == null);
    var copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer copy.deinit(allocator);
    switch (copy.command.?) {
        .copy_source_selection => |text| try std.testing.expectEqualStrings("A", text),
        else => return error.ExpectedSourceCopyCommand,
    }
}

test "repository selection candidate and clipboard allocation failures have separate terminals" {
    const backing = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };

    {
        var state = try selectionStateForTest("main.zig\x00", "ABC\n");
        try installFirstLineCandidateForTest(&state, backing);
        const document = state.currentSource().?;
        const line = document.lineBody(0).?;
        var live = repository_selection.DragSelection.init(
            state.currentContentToken().?,
            .character,
            repository_selection.pointFromBoundary(0, 0),
        );
        live.update(repository_selection.pointFromBoundary(0, line.len));
        state.selection_owner = .{ .source = live };
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
        defer state.deinit(failing.allocator());
        var update = state.applyNavigation(failing.allocator(), .{ .mouse_owner_release = null }, size);
        defer update.deinit(failing.allocator());
        try std.testing.expect(update.command == null);
        try std.testing.expectEqualStrings("ABC", state.completed_selection.?.text);
        try std.testing.expect(!state.activeMouseSourceRange());
    }

    var observed_clipboard_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 16 and !observed_clipboard_failure) : (fail_index += 1) {
        var state = try selectionStateForTest("main.zig\x00", "ABC\n");
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        defer state.deinit(failing.allocator());
        const document = state.currentSource().?;
        const line = document.lineBody(0).?;
        var live = repository_selection.DragSelection.init(
            state.currentContentToken().?,
            .character,
            repository_selection.pointFromBoundary(0, 0),
        );
        live.update(repository_selection.pointFromBoundary(0, line.len));
        state.selection_owner = .{ .source = live };
        var update = state.applyNavigation(failing.allocator(), .{ .mouse_owner_release = null }, size);
        defer update.deinit(failing.allocator());
        if (state.completed_selection != null) {
            var copy = state.applyNavigation(failing.allocator(), .{ .selection_action = .copy }, size);
            defer copy.deinit(failing.allocator());
            if (copy.command != null) continue;
            observed_clipboard_failure = true;
            try std.testing.expectEqualStrings("ABC", state.completed_selection.?.text);
            try std.testing.expect(!state.activeMouseSourceRange());
        }
    }
    try std.testing.expect(observed_clipboard_failure);
}

test "repository selection stale release clears prior candidate" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABC\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    var token = state.currentContentToken().?;
    token.source_fingerprint = .init("different");
    var live = repository_selection.DragSelection.init(
        token,
        .line,
        repository_selection.pointFromLine(0),
    );
    live.moved = true;
    state.selection_owner = .{ .source = live };

    var update = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, .{ .width = 60, .height = 6 });
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expect(!state.activeMouseSourceRange());
}

test "repository selection real empty line keeps candidate without copy command" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "\nnext\n");
    defer state.deinit(allocator);
    var live = repository_selection.DragSelection.init(
        state.currentContentToken().?,
        .line,
        repository_selection.pointFromLine(0),
    );
    live.moved = true;
    state.selection_owner = .{ .source = live };

    var update = state.applyNavigation(allocator, .{ .mouse_owner_release = null }, .{ .width = 60, .height = 6 });
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("", state.completed_selection.?.text);
    try std.testing.expectEqualStrings("", state.status.text());
    var copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, .{ .width = 60, .height = 6 });
    defer copy.deinit(allocator);
    switch (copy.command.?) {
        .copy_source_selection => |text| try std.testing.expectEqualStrings("", text),
        else => return error.ExpectedSourceCopyCommand,
    }
    try std.testing.expect(state.completed_selection != null);
}

test "repository selection reconciles accepted document and keeps other replacements fail closed" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };

    {
        var state = try selectionStateForTest("main.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        state.repositoryChanged(allocator, 9, .{ .device = 10, .inode = 11 });
        try std.testing.expect(state.completed_selection == null);
    }
    {
        var state = try selectionStateForTest("a.zig\x00b.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        state.viewer.focus = .tree;
        const update = state.applyNavigation(allocator, .move_down, size);
        try std.testing.expect(update.selected_path_changed);
        try std.testing.expect(state.completed_selection == null);
    }
    {
        var state = try selectionStateForTest("main.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        var incoming = try bundleForTest("other.zig\x00");
        var incoming_owned = true;
        defer if (incoming_owned) incoming.deinit(allocator);
        try state.replaceBundle(allocator, &incoming);
        incoming_owned = false;
        try std.testing.expect(state.completed_selection == null);
    }

    // A different delivery generation and new allocation do not change the
    // semantic basis. Changed or inert source cannot retain the candidate.
    try expectDocumentReplacementCandidateForTest("old source\n", true);
    try expectDocumentReplacementCandidateForTest("changed source\n", false);
    try expectDocumentReplacementCandidateForTest(null, false);
}

test "repository document replacement restores semantic viewport across projection terminals" {
    const allocator = std.testing.allocator;
    const original = "zero\none\ntwo\nthree\nfour\n";
    var state = try selectionStateForTest("main.zig\x00", original);
    defer state.deinit(allocator);
    var drag = repository_selection.DragSelection.init(
        state.currentContentToken().?,
        .line,
        repository_selection.pointFromLine(1),
    );
    drag.moved = true;
    state.completed_selection = try repository_selection.buildCompletedSelection(
        allocator,
        state.currentSource().?,
        drag,
    );
    state.viewer.source_vertical_scroll = 2;

    state.document_generation = 8;
    state.pending_document_generation = 8;
    const exact_bytes = try allocator.dupe(u8, original);
    var exact: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .source = try source_document.Document.initOwned(allocator, exact_bytes, .init(exact_bytes)) },
    };
    defer exact.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &exact));
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.source_vertical_scroll);

    state.document_generation = 9;
    state.pending_document_generation = 9;
    const changed_content = "ZERO\none\ntwo\nthree\nfour\n";
    const changed_bytes = try allocator.dupe(u8, changed_content);
    var changed: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .source = try source_document.Document.initOwned(allocator, changed_bytes, .init(changed_bytes)) },
    };
    defer changed.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &changed));
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
}

test "repository selection retains candidate across inactive page and presentation changes" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var state = try selectionStateForTest("main.zig\x00", "first\nneedle here\nthird\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    const retained_token = state.completed_selection.?.token.view();

    state.deactivate();
    try std.testing.expect(state.completed_selection != null);
    state.activate(state.repo_epoch, state.root_identity);
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));
    var pending_copy = state.applyNavigation(allocator, .{ .selection_action = .copy }, size);
    defer pending_copy.deinit(allocator);
    try std.testing.expect(pending_copy.command != null);
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    _ = state.applyNavigation(allocator, .focus_source, size);
    _ = state.applyNavigation(allocator, .source_last, size);
    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("needle") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    state.syntax_generation = 8;
    state.pending_syntax_generation = 8;
    var syntax_finished = repository_tasks.SyntaxFinished{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .source_revision = state.displayed_document.?.source_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .fingerprint = state.currentSource().?.fingerprint,
        .result = .unavailable,
    };
    defer syntax_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applySyntaxFinished(allocator, &syntax_finished));
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    state.displayed_document.?.change_decoration = .eligible;
    state.change_map_generation = 9;
    state.pending_change_map_generation = 9;
    var change_finished = repository_tasks.ChangeMapFinished{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = state.manifest_revision,
        .source_revision = state.displayed_document.?.source_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .fingerprint = state.currentSource().?.fingerprint,
        .content_line_count = state.currentSource().?.contentLineCount(),
        .result = .unavailable,
    };
    defer change_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyChangeMapFinished(allocator, &change_finished));
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    // Reactivation retains last-good bytes but requires revalidation, so a new
    // drag is not admitted. The release-frozen candidate still survives cancel
    // and resize presentation events.
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    _ = state.applyNavigation(allocator, .cancel_mouse_owner, size);
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    state.cancelMouseOwner();
    state.clampForBodySize(.{ .width = 50, .height = 5 });
    try std.testing.expect(!state.activeMouseSourceRange());
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));
}

test "repository source completion rejects stale identity and frees undelivered payload" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .repo_epoch = 4,
        .activation_id = 5,
        .root_identity = .{ .device = 6, .inode = 7 },
        .manifest_revision = 8,
        .document_generation = 9,
        .pending_document_generation = 9,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.source_cursor = 20;
    state.viewer.source_vertical_scroll = 10;
    state.viewer.source_horizontal_scroll = 30;
    try state.source_search.query.insertSlice("retained-on-stale");
    state.source_search.mode = true;
    state.source_search.match = .{ .line = 1, .start = 0, .end = 1 };

    const stale_bytes = try allocator.dupe(u8, "stale\n");
    var stale = repository_tasks.DocumentFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, stale_bytes, .init(stale_bytes)) },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expectEqualStrings("retained-on-stale", state.source_search.query.slice());

    const owned_bytes = try allocator.dupe(u8, "owned\n");
    var undelivered = Msg{ .document_finished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned_bytes, .init(owned_bytes)) },
    } };
    undelivered.deinitUndelivered(allocator);

    const matching_bytes = try allocator.dupe(u8, "retained-on-stale\n");
    const modified_at: std.Io.Timestamp = .{ .nanoseconds = 123_456_789 };
    var matching = repository_tasks.DocumentFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, matching_bytes, .init(matching_bytes)) },
        .metadata = .{ .modified_at = modified_at },
    };
    defer matching.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &matching));
    try std.testing.expect(matching.metadata == null);
    try std.testing.expectEqual(
        modified_at.nanoseconds,
        state.displayed_document.?.metadata.?.modified_at.nanoseconds,
    );
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.source_search.query.len);
    try std.testing.expect(!state.source_search.mode);
    try std.testing.expect(state.source_search.match == null);
    try std.testing.expectEqual(source_syntax_runtime.enabled, state.needs_syntax_request);
    try std.testing.expectEqual(source_syntax_runtime.enabled, state.wantsSyntaxRequest());

    state.pending_document_generation = 10;
    state.rejectDocumentSpawn(10);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expectEqualStrings("Could not start selected file task", state.status.text());
}

test "repository minimum tree disclosure page layout and mouse mapping share tree geometry" {
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/file.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(std.testing.allocator);

    const wide = chasen.Size{ .width = 60, .height = 10 };
    const wide_layout = repository_layout.bodyLayout(wide, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(u16, 28), wide_layout.tree_width);
    try std.testing.expectEqual(@as(u16, 3), wide_layout.header_rows);
    try std.testing.expectEqual(@as(u16, 7), wide_layout.treeRows(wide.height));
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 1, .row = 0 }, .left, wide).?);
    try std.testing.expect(state.mouseToMsg(.{ .col = wide_layout.tree_width, .row = 1 }, .left, wide) == null);
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 1, .row = 2 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 0 }, state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 1 }, state.mouseToMsg(.{ .col = 1, .row = 4 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_row = 2 }, state.mouseToMsg(.{ .col = 1, .row = 5 }, .left, wide).?);
    try std.testing.expectEqual(Msg.wheel_down, state.mouseToMsg(.{ .col = 1, .row = 0 }, .wheel_down, wide).?);

    const directory_toggle = state.mouseToMsg(.{ .col = 1, .row = 4 }, .left, wide).?;
    _ = state.applyNavigation(std.testing.allocator, directory_toggle, wide);
    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    const root_toggle = state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, wide).?;
    _ = state.applyNavigation(std.testing.allocator, root_toggle, wide);
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);
    try std.testing.expectEqual(@as(usize, 4), state.tree_projection.visibleLen(&state.bundle.?.tree));
    _ = state.applyNavigation(std.testing.allocator, root_toggle, wide);
    try std.testing.expect(state.bundle.?.tree.nodes[directory].expanded);

    const narrow = chasen.Size{ .width = 20, .height = 6 };
    try std.testing.expectEqual(narrow.width, repository_layout.bodyLayout(narrow, state.viewer.tree_width, state.viewer.tree_hidden).tree_width);
    try std.testing.expectEqual(Msg{ .mouse_row = 2 }, state.mouseToMsg(.{ .col = 19, .row = 5 }, .left, narrow).?);
}

test "repository tree width controls share rendering mouse and source geometry" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    state.viewer.focus = .source;

    const size = chasen.Size{ .width = 104, .height = 10 };
    try std.testing.expectEqual(@as(u16, 34), repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden).tree_width);

    _ = state.applyNavigation(allocator, .decrease_tree_width, size);
    try std.testing.expectEqual(@as(?u16, 30), state.viewer.tree_width);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);

    const adjusted = repository_layout.bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(u16, 30), adjusted.tree_width);
    try std.testing.expectEqual(@as(u16, 73), state.sourceGeometry(size, state.currentSource().?).width);
    try std.testing.expect(state.mouseToMsg(.{ .col = adjusted.tree_width, .row = 0 }, .left, size) == null);
    try std.testing.expectEqual(
        Msg.focus_source,
        state.mouseToMsg(.{ .col = adjusted.tree_width + 1, .row = 0 }, .left, size).?,
    );
    try std.testing.expectEqual(
        repository_layout.BodyPoint{ .col = 4, .row = 2 },
        repository_layout.sourceGesturePoint(.{ .col = adjusted.tree_width + 1 + 4, .row = 2 }, size, state.viewer.tree_width, state.viewer.tree_hidden).?,
    );

    _ = state.applyNavigation(allocator, .increase_tree_width, size);
    try std.testing.expectEqual(@as(?u16, 34), state.viewer.tree_width);
}

test "repository transition incoming lifecycle keeps one destination owner" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .selected_path = "retained.zig",
    };
    defer state.deinit(allocator);

    var location = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "target.zig", .line = 9 } },
    );
    state.acceptIncoming(allocator, &location);
    try std.testing.expect(state.incomingIsPending());
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    state.deactivate();
    try std.testing.expect(state.incomingIsPending());
    state.activate(4, identity);
    try std.testing.expect(state.incomingIsPending());
    state.requestReload(true);
    try std.testing.expect(state.incomingIsPending());

    _ = state.applyNavigation(allocator, .toggle_line_numbers, .{ .width = 80, .height = 10 });
    try std.testing.expect(state.incomingIsPending());
    _ = state.applyNavigation(allocator, .cancel_file_search, .{ .width = 80, .height = 10 });
    try std.testing.expect(state.incomingIsPending());

    _ = state.applyNavigation(allocator, .move_down, .{ .width = 80, .height = 10 });
    try std.testing.expect(!state.incomingIsPending());
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var unavailable = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .unavailable = .{ .path = "deleted.zig", .reason = .no_current_path } },
    );
    state.acceptIncoming(allocator, &unavailable);
    try std.testing.expectEqualStrings("deleted.zig", state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var successor = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "successor.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &successor);
    try std.testing.expect(state.incomingIsPending());
    try std.testing.expectEqualStrings("successor.zig", state.incoming.awaiting_manifest.path);

    state.repositoryChanged(allocator, 8, .{ .device = 13, .inode = 21 });
    try std.testing.expect(!state.incomingIsPending());
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expect(state.selected_path == null);
}

test "repository incoming viewport scroll places immediate target from root with real tree rows" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("src/app.zig\x00src/app/pages/repository.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(
        &state.bundle.?,
        " M src/app.zig\x00 M src/app/pages/repository.zig\x00",
    );
    state.bundle.?.tree.rebuildVisibleFor(.changed);
    state.selected_path = state.bundle.?.tree.filePath("src/app.zig", .changed);
    state.viewer.tree_cursor = 2;
    state.viewer.tree_vertical_scroll = 99;

    var fitting = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/app/pages/repository.zig" } },
    );
    state.acceptIncoming(allocator, &fitting);
    try std.testing.expect(state.resolveIncomingAfterActivation(
        allocator,
        .{ .width = 80, .height = 31 },
    ));
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_vertical_scroll);
    try std.testing.expectEqual(
        repository_tree_projection.Target.repo_root,
        state.tree_projection.targetAt(&state.bundle.?.tree, 0).?,
    );
    try expectProjectedPathForTest(&state, 1, "src");
    try expectProjectedPathForTest(&state, 2, "src/app");
    try expectProjectedPathForTest(&state, 3, "src/app/pages");
    try expectProjectedPathForTest(&state, 4, "src/app/pages/repository.zig");
    try expectProjectedPathForTest(&state, 5, "src/app.zig");

    state.dismissIncoming(allocator);
    var narrow = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/app/pages/repository.zig" } },
    );
    state.acceptIncoming(allocator, &narrow);
    const narrow_body: chasen.Size = .{ .width = 80, .height = 7 };
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, narrow_body));
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_vertical_scroll);
    try expectProjectedPathForTest(&state, 1, "src");
    try expectProjectedPathForTest(&state, 4, "src/app/pages/repository.zig");

    _ = state.applyNavigation(allocator, .move_up, narrow_body);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_vertical_scroll);
    _ = state.applyNavigation(allocator, .move_down, narrow_body);
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_vertical_scroll);

    state.dismissIncoming(allocator);
    var zero_rows = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/app/pages/repository.zig" } },
    );
    state.acceptIncoming(allocator, &zero_rows);
    try std.testing.expect(state.resolveIncomingAfterActivation(
        allocator,
        .{ .width = 80, .height = 3 },
    ));
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_vertical_scroll);
    state.clampForBodySize(.{ .width = 80, .height = 8 });
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_vertical_scroll);
}

test "repository incoming viewport scroll preserves same-target source viewport" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest(
        "src/app/pages/repository.zig\x00",
        "0123456789abcdefghijklmnop\n1\n2\n3\n4\n5\n6\n7\n",
    );
    defer state.deinit(allocator);
    state.freshness = .fresh;
    state.viewer.focus = .source;
    state.viewer.source_cursor = 6;
    state.viewer.source_vertical_scroll = 0;
    state.viewer.source_horizontal_scroll = 9;
    const identity = state.root_identity.?;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        identity,
        .{ .location = .{ .path = "src/app/pages/repository.zig" } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(
        allocator,
        .{ .width = 20, .height = 4 },
    ));

    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 6), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 9), state.viewer.source_horizontal_scroll);
}

test "repository incoming viewport scroll applies deferred manifest with the same placement" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 7,
        .pending_generation = 7,
        .load_state = .loading,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/app/pages/repository.zig" } },
    );
    state.acceptIncoming(allocator, &incoming);

    var bundle = try bundleForTest("src/app.zig\x00src/app/pages/repository.zig\x00");
    try applyBundleStatusForTest(
        &bundle,
        " M src/app.zig\x00 M src/app/pages/repository.zig\x00",
    );
    var finished: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .loaded = bundle },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(
        ApplyOutcome.changed,
        state.applyFinished(allocator, &finished, .{ .width = 80, .height = 7 }),
    );
    try std.testing.expectEqualStrings(
        "src/app/pages/repository.zig",
        state.selected_path.?,
    );
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_vertical_scroll);
    try expectProjectedPathForTest(&state, 1, "src");
    try expectProjectedPathForTest(&state, 4, "src/app/pages/repository.zig");
}

test "repository minimum tree disclosure repository filter discoverability Review incoming expands only exact ancestors" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("dir/target.zig\x00other/nested.zig\x00changed.zig\x00retained.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.bundle.?.tree.rebuildVisibleFor(.changed);
    state.selected_path = state.bundle.?.tree.filePath("changed.zig", .changed);
    state.all_selection_anchor = try allocator.dupe(u8, "retained.zig");
    state.viewer.tree_cursor = 0;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "dir/target.zig", .line = 9 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));

    try std.testing.expect(state.incoming == .awaiting_document);
    const pending = state.incoming.documentIntent().?;
    try std.testing.expectEqual(owned_address, @intFromPtr(pending.location.path.ptr));
    try std.testing.expectEqual(@as(u64, 6), pending.manifest_revision);
    try std.testing.expectEqual(@as(?u32, 9), pending.location.line);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expect(state.bundle.?.tree.nodes[state.bundle.?.tree.nodeIndexForPath("dir", .all).?].expanded);
    try std.testing.expect(!state.bundle.?.tree.nodes[state.bundle.?.tree.nodeIndexForPath("other", .all).?].expanded);
    const selected_target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedSelectedTarget;
    switch (selected_target) {
        .repo_root => return error.ExpectedFileTarget,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            "dir/target.zig",
            state.bundle.?.tree.nodes[node_index].path,
        ),
    }
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expectEqualStrings("Review target opened in All files", state.status.text());
}

test "repository minimum tree disclosure Review incoming root file opens no directory" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("dir/nested.zig\x00other/deep/file.zig\x00root-target.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("dir/nested.zig", .all);
    state.viewer.tree_cursor = 0;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "root-target.zig", .line = 3 } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));

    try std.testing.expectEqualStrings("root-target.zig", state.selected_path.?);
    for (state.bundle.?.tree.nodes) |node| {
        if (node.kind == .directory) try std.testing.expect(!node.expanded);
    }
    const selected_target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedSelectedTarget;
    switch (selected_target) {
        .repo_root => return error.ExpectedFileTarget,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            "root-target.zig",
            state.bundle.?.tree.nodes[node_index].path,
        ),
    }
    const pending = state.incoming.documentIntent() orelse return error.ExpectedDocumentIntent;
    try std.testing.expectEqual(@as(?u32, 3), pending.location.line);
    try std.testing.expectEqualStrings("root-target.zig", pending.location.path);
}

test "repository transition exact failures retain prior browser location" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("retained.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var missing = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "missing.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &missing);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.path_not_found, state.incomingUnavailable().?.reason);
    try std.testing.expectEqualStrings("missing.zig", state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var wrong_repository = try page_link.RepositoryIncoming.initOwned(
        allocator,
        9,
        identity,
        .{ .location = .{ .path = "retained.zig", .line = 1 } },
    );
    state.acceptIncoming(allocator, &wrong_repository);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, state.incomingUnavailable().?.reason);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);
}

test "repository transition first owner install waits for activation identity" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("retained.zig\x00target.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "target.zig", .line = 3 } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    state.activate(4, identity);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqualStrings("target.zig", state.selected_path.?);
    try std.testing.expectEqual(@as(?u32, 3), state.incoming.documentIntent().?.location.line);
}

test "repository transition resolves or terminalizes matching manifest completion" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 7,
        .pending_generation = 7,
        .load_state = .loading,
    };
    defer state.deinit(allocator);

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var finished: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .loaded = try bundleForTest("README.md\x00src/main.zig\x00") },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqualStrings("src/main.zig", state.selected_path.?);
    try std.testing.expectEqual(@as(u64, 1), state.incoming.documentIntent().?.manifest_revision);
    try std.testing.expect(state.needs_document_revalidation);

    state.dismissIncoming(allocator);
    state.generation = 8;
    state.pending_generation = 8;
    var failed_incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/main.zig", .line = null } },
    );
    state.incoming.accept(allocator, &failed_incoming);
    var failed: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "manifest failed" },
    };
    defer failed.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &failed, test_body_size));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, state.incomingUnavailable().?.reason);
}

test "repository accepted current source excludes retained revalidation authority" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;

    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);

    state.needs_revalidation = true;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.needs_revalidation = false;

    state.needs_document_revalidation = true;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.needs_document_revalidation = false;

    state.pending_generation = 9;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.pending_generation = null;

    state.pending_document_generation = 11;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.pending_document_generation = null;

    state.freshness = .validating;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.freshness = .fresh;

    state.active = false;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.active = true;

    state.activation_id = 0;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.activation_id = 2;

    const root_identity = state.root_identity.?;
    state.root_identity = null;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.root_identity = root_identity;

    state.displayed_document.?.authority = .revalidation_required;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.displayed_document.?.authority = .accepted;

    state.displayed_document.?.manifest_revision += 1;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
}

test "repository accepted source authority requires a matching completion after spawn rejection" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;

    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);
    state.requireDocumentRevalidation();
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    var rejected_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer rejected_request.deinit(allocator);
    try std.testing.expectEqual(
        DisplayedDocument.Authority.revalidation_required,
        state.displayed_document.?.authority,
    );
    state.rejectDocumentSpawn(rejected_request.generation);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    // A later explicit retry may schedule work, but scheduling alone still
    // cannot promote the retained bytes.
    state.requireDocumentRevalidation();
    var accepted_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer accepted_request.deinit(allocator);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    const replacement = try allocator.dupe(u8, "accepted replacement\n");
    var finished: repository_tasks.DocumentFinished = .{
        .identity = accepted_request.identity,
        .root_identity = root.capability.identity,
        .generation = accepted_request.generation,
        .manifest_revision = accepted_request.manifest_revision,
        .path = try allocator.dupe(u8, accepted_request.path),
        .value = .{ .source = try source_document.Document.initOwned(
            allocator,
            replacement,
            .init(replacement),
        ) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(
        DisplayedDocument.Authority.accepted,
        state.displayed_document.?.authority,
    );
    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);
}

fn fileSearchDocumentFinishedForTest(
    allocator: std.mem.Allocator,
    request: *const repository_tasks.DocumentRequest,
    content: ?[]const u8,
) !repository_tasks.DocumentFinished {
    var value: repository_tasks.DocumentValue = if (content) |source| blk: {
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        break :blk .{ .source = try source_document.Document.initOwned(
            allocator,
            bytes,
            .init(bytes),
        ) };
    } else .{ .inert = .binary };
    errdefer switch (value) {
        .source => |*document| document.deinit(allocator),
        .inert => {},
    };
    return .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = value,
    };
}

test "repository file search focus uses an already accepted same-path source immediately" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "accepted source\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    state.viewer.focus = .tree;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);

    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);
}

test "repository file search focus binds a prepared successor and consumes accepted source" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "old alpha\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_next, size);
    var update = state.applyNavigation(allocator, .submit_file_search, size);
    defer update.deinit(allocator);

    try std.testing.expect(update.selected_path_changed);
    try std.testing.expectEqualStrings("beta.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expect(state.currentSource() == null);
    try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(
        request.generation,
        state.pending_document_request.?.generation,
    );

    var finished = try fileSearchDocumentFinishedForTest(allocator, &request, "accepted beta\n");
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("accepted beta\n", state.currentSource().?.bytes);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);
}

test "repository file search focus directly binds an exact pending request" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "last good\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.requireDocumentRevalidation();

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);

    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);

    var stale = try fileSearchDocumentFinishedForTest(allocator, &request, "stale\n");
    stale.generation -|= 1;
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(@as(?u64, request.generation), state.pending_document_generation);

    var accepted = try fileSearchDocumentFinishedForTest(allocator, &request, "accepted\n");
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &accepted));
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(state.file_search_source_focus == .none);
}

test "repository file search focus rejects an incompatible pending request basis" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "last good\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.requireDocumentRevalidation();

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    const exact = state.pending_document_request.?;
    var mismatches = [_]repository_file_search_focus.PendingDocumentRequest{ exact, exact, exact, exact };
    mismatches[0].basis.activation_id +%= 1;
    mismatches[1].basis.root_identity.inode +%= 1;
    mismatches[2].basis.manifest_revision +%= 1;
    mismatches[3].basis.path = "other.zig";
    for (mismatches) |mismatch| {
        state.pending_document_request = mismatch;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);

        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(@as(?u64, request.generation), state.pending_document_generation);
    }

    state.pending_document_request = exact;
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
}

test "repository file search focus clears borrowed intent on selection reload and deactivation" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_next, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

    _ = state.applyNavigation(allocator, .move_up, size);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
    try std.testing.expect(state.file_search_source_focus == .none);

    state.file_search_source_focus.awaitDocumentRequest(state.currentFileSearchFocusBasis().?);
    state.requestReload(true);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);

    state.file_search_source_focus.awaitDocumentRequest(state.currentFileSearchFocusBasis().?);
    state.deactivate();
    try std.testing.expect(state.file_search_source_focus == .none);
}

test "repository file search focus closes preparation spawn and inert terminals" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

        state.markDocumentRequestPreparationFailed(error.OutOfMemory);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    }

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        var request = try state.prepareDocumentRequest(allocator, &root.capability);
        defer request.deinit(allocator);
        state.rejectDocumentSpawn(request.generation);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expect(state.pending_document_request == null);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    }

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        var request = try state.prepareDocumentRequest(allocator, &root.capability);
        defer request.deinit(allocator);
        var inert = try fileSearchDocumentFinishedForTest(allocator, &request, null);
        defer inert.deinit(allocator);
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &inert));
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
        try std.testing.expect(state.displayed_document.?.value == .inert);
    }
}

test "repository capability terminal cannot promote retained source authority" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "retained source\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.requireDocumentRevalidation();
    state.markDocumentCapabilityUnavailable();

    try std.testing.expectEqual(
        page_link.RepositoryUnavailableReason.request_failed,
        state.incomingUnavailable().?.reason,
    );
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
}

test "repository transition resolves an already accepted source without a task" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\nthree\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    const source_address = @intFromPtr(state.currentSource().?);
    const cases = [_]struct { line: u32, cursor: usize }{
        .{ .line = 1, .cursor = 0 },
        .{ .line = 2, .cursor = 1 },
        .{ .line = 99, .cursor = 2 },
    };
    for (cases) |case| {
        state.viewer.focus = .tree;
        var incoming = try page_link.RepositoryIncoming.initOwned(
            allocator,
            state.repo_epoch,
            state.root_identity.?,
            .{ .location = .{ .path = "main.zig", .line = case.line } },
        );
        state.acceptIncoming(allocator, &incoming);
        try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
        try std.testing.expect(state.incoming == .none);
        try std.testing.expectEqual(source_address, @intFromPtr(state.currentSource().?));
        try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
        try std.testing.expectEqual(case.cursor, state.viewer.source_cursor);
        try std.testing.expectEqual(case.cursor, state.viewer.source_vertical_scroll);
        try std.testing.expect(!state.needs_document_revalidation);
    }

    state.viewer.focus = .tree;
    state.viewer.source_cursor = 1;
    state.viewer.source_vertical_scroll = 1;
    var path_only = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &path_only);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);
}

fn expectReactivatedIncomingDocumentForTest(
    line: ?u32,
    replacement_source: ?[]const u8,
    expected_cursor: ?usize,
) !void {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old one\nold two\nold three\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.viewer.focus = .tree;
    state.viewer.source_cursor = 1;
    state.viewer.source_vertical_scroll = 1;

    state.deactivate();
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = line } },
    );
    state.acceptIncoming(allocator, &incoming);
    state.activate(state.repo_epoch, root.capability.identity);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: repository_tasks.ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(allocator, &manifest_finished, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_document_revalidation);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    const value: repository_tasks.DocumentValue = if (replacement_source) |content| blk: {
        const bytes = try allocator.dupe(u8, content);
        break :blk .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) };
    } else .{ .inert = .binary };
    var document_finished: repository_tasks.DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = value,
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));

    if (expected_cursor) |cursor| {
        try std.testing.expect(state.incoming == .none);
        try std.testing.expectEqual(cursor, state.viewer.source_cursor);
        try std.testing.expectEqual(cursor, state.viewer.source_vertical_scroll);
        try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
        try std.testing.expectEqualStrings(replacement_source.?, state.currentSource().?.bytes);
    } else {
        try std.testing.expectEqual(
            page_link.RepositoryUnavailableReason.source_unavailable,
            state.incomingUnavailable().?.reason,
        );
        try std.testing.expect(state.displayed_document.?.value == .inert);
    }
}

test "repository transition reactivation waits for current source authority" {
    try expectReactivatedIncomingDocumentForTest(2, "new one\nnew two\nnew three\n", 1);
    try expectReactivatedIncomingDocumentForTest(null, "new one\nnew two\nnew three\n", 0);
    try expectReactivatedIncomingDocumentForTest(2, null, null);
}

fn expectIncomingDocumentLineForTest(
    content: []const u8,
    line: ?u32,
    expected_cursor: usize,
    inactive_completion: bool,
) !void {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = line } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.wantsDocumentRequest());

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expectEqual(
        @as(?u64, request.generation),
        state.incoming.documentIntent().?.document_generation,
    );
    if (inactive_completion) state.deactivate();
    const bytes = try allocator.dupe(u8, content);
    var finished: repository_tasks.DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(expected_cursor, state.viewer.source_cursor);
    try std.testing.expectEqual(expected_cursor, state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(!inactive_completion, state.active);
}

test "repository transition binds completion and clamps current source lines" {
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", null, 0, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 1, 0, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 2, 1, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 99, 2, true);
    try expectIncomingDocumentLineForTest("", 99, 0, false);
}

test "repository transition inert document moves request path to unavailable" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 1 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    var finished: repository_tasks.DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .inert = .binary },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.source_unavailable, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.displayed_document.?.value == .inert);
}

test "repository transition wrong root terminalizes the bound owner" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 1 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator, test_body_size));
    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const bytes = try allocator.dupe(u8, "source\n");
    var finished: repository_tasks.DocumentFinished = .{
        .identity = request.identity,
        .root_identity = .{
            .device = request.root.identity.device,
            .inode = request.root.identity.inode +% 1,
        },
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &finished));
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expect(state.displayed_document == null);
}

fn acceptIncomingFailureOwnerForTest(
    state: *RepositoryPageState,
    allocator: std.mem.Allocator,
    path: []const u8,
) !usize {
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = path, .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    return owned_address;
}

fn expectIncomingRequestFailureForTest(state: *const RepositoryPageState, owned_address: usize) !void {
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
}

test "repository transition manifest start failures close the owner" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = .{ .device = 5, .inode = 6 },
        .needs_revalidation = true,
    };
    defer state.deinit(allocator);

    const preparation_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "manifest-preparation.zig");
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, preparation_address);

    const spawn_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "manifest-spawn.zig");
    state.pending_generation = 8;
    state.rejectSpawn(7);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(@as(?u64, 8), state.pending_generation);
    state.rejectSpawn(8);
    try expectIncomingRequestFailureForTest(&state, spawn_address);
    try std.testing.expect(state.pending_generation == null);

    const predecessor_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "predecessor.zig");
    state.generation = 13;
    state.pending_generation = 13;
    state.requestReload(true);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(@as(?u64, 13), state.pending_generation);
    try std.testing.expectEqual(predecessor_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    var predecessor_finished: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 13,
        .result = .{ .loaded = try bundleForTest("predecessor.zig\x00") },
    };
    defer predecessor_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &predecessor_finished, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(predecessor_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    const missing_repository_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "missing-repository.zig");
    state.requestReload(false);
    try expectIncomingRequestFailureForTest(&state, missing_repository_address);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
}

test "repository transition document start failures close the bound owner" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = .{ .device = 5, .inode = 6 },
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    const preparation_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.markDocumentRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, preparation_address);

    const spawn_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 12;
    state.pending_document_generation = 12;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));
    state.rejectDocumentSpawn(11);
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(@as(?u64, 12), state.pending_document_generation);
    state.rejectDocumentSpawn(12);
    try expectIncomingRequestFailureForTest(&state, spawn_address);
    try std.testing.expect(state.pending_document_generation == null);

    const capability_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.needs_document_revalidation = true;
    state.markDocumentCapabilityUnavailable();
    try expectIncomingRequestFailureForTest(&state, capability_address);
    try std.testing.expect(!state.needs_document_revalidation);
}

test "repository transition manual reload rebinds one destination through manifest" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old one\nold two\nold three\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 7;
    state.pending_document_generation = 7;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 7));

    state.requestReload(true);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(state.needs_revalidation);

    const stale_bytes = try allocator.dupe(u8, "stale source\n");
    var stale_document: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 7,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, stale_bytes, .init(stale_bytes)) },
    };
    defer stale_document.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale_document));
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: repository_tasks.ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &manifest_finished, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_document_revalidation);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    try std.testing.expect(document_request.generation > 7);
    try std.testing.expectEqual(
        @as(?u64, document_request.generation),
        state.incoming.documentIntent().?.document_generation,
    );
    const new_bytes = try allocator.dupe(u8, "new one\nnew two\nnew three\n");
    var document_finished: repository_tasks.DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, new_bytes, .init(new_bytes)) },
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqualStrings("new one\nnew two\nnew three\n", state.currentSource().?.bytes);
}

test "repository transition reactivation rewinds or terminalizes document owner" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = root.capability.identity,
        .manifest_revision = 11,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    const retained_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "retained.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "retained.zig", 12));

    state.deactivate();
    state.activate(state.repo_epoch, root.capability.identity);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(retained_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(state.needs_revalidation);

    var stale_document: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = root.capability.identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "retained.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale_document.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale_document));
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: repository_tasks.ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .loaded = try bundleForTest("retained.zig\x00") },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &manifest_finished, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    const bytes = try allocator.dupe(u8, "first\nsecond\nthird\n");
    var document_finished: repository_tasks.DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);

    const unavailable_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "no-root.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.activate(state.repo_epoch, null);
    try expectIncomingRequestFailureForTest(&state, unavailable_address);
    try std.testing.expect(!state.needs_revalidation);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
}

test "repository transition reactivation invalidates manifest predecessor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = identity,
        .generation = 7,
        .pending_generation = 7,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "pending.zig");

    state.deactivate();
    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.pending_generation == null);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);

    var stale_manifest: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .loaded = try bundleForTest("pending.zig\x00") },
    };
    defer stale_manifest.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale_manifest, test_body_size));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.bundle == null);
}

test "repository transition manifest mismatch keeps a current task successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
        .pending_generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "target.zig");

    var stale: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .failed_static = "stale manifest" },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    var current: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .loaded = try bundleForTest("target.zig\x00") },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &current, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    // The manifest payload has no document-acceptance authority, but its
    // rejection still classifies the remaining owner's liveness. The accepted
    // manifest scheduled document revalidation, so that successor retains it.
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_document);

    // Without that named document successor, the same reverse cross-stage
    // rejection closes the same path owner instead of retaining it forever.
    state.needs_document_revalidation = false;
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &stale, test_body_size));
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition manifest mismatch keeps a scheduled successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
        .needs_revalidation = true,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "scheduled.zig");

    var unmatched: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "unmatched manifest" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &unmatched, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    // If the named scheduled attempt cannot be prepared, its existing
    // start-failure contract closes the same owner instead of adding a retry.
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition manifest mismatch keeps a dormant successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = false,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "dormant.zig");

    var unmatched: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .failed_static = "old activation" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &unmatched, test_body_size));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition manifest mismatch without successor closes owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "orphaned.zig");

    // The completion names the current generation but no pending task owns
    // that generation and no revalidation is scheduled.
    var unmatched: repository_tasks.ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "unowned completion" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &unmatched, test_body_size));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.bundle == null);
}

test "repository transition document mismatch keeps a current task successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));

    var stale: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision - 1,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(@as(?u64, 12), state.pending_document_generation);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    const bytes = try allocator.dupe(u8, "one\ntwo\nthree\n");
    var current: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &current));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
}

test "repository transition document mismatch keeps a scheduled successor" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
        .needs_document_revalidation = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));

    var stale: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = root.capability.identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision - 1,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expect(request.generation > 12);
    const bytes = try allocator.dupe(u8, "new one\nnew two\nnew three\n");
    var current: repository_tasks.DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &current));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
}

test "repository transition document mismatch keeps a dormant successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = false,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .manifest_revision = 9,
        .document_generation = 12,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "dormant.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "dormant.zig", 11));

    var stale: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "dormant.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition document mismatch without successor closes owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 11));

    var stale: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &stale));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.displayed_document == null);

    state.dismissIncoming(allocator);
    const wrong_path_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 13;
    state.pending_document_generation = 13;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 13));
    var wrong_path: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 13,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "other.zig"),
        .value = .{ .inert = .binary },
    };
    defer wrong_path.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &wrong_path));
    try expectIncomingRequestFailureForTest(&state, wrong_path_address);

    // Cross-stage rejection evaluates the manifest owner's own liveness. The
    // document root failure is not its terminal reason, but a scheduled
    // manifest revalidation is a valid reason to retain it.
    state.dismissIncoming(allocator);
    const manifest_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    state.needs_revalidation = true;
    state.document_generation = 14;
    state.pending_document_generation = 14;
    var wrong_root: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = .{ .device = identity.device, .inode = identity.inode +% 1 },
        .generation = 14,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer wrong_root.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &wrong_root));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(manifest_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    // Once that named successor disappears, a later cross-stage rejection
    // closes the orphaned manifest owner rather than leaving it pending.
    state.needs_revalidation = false;
    state.document_generation = 15;
    state.pending_document_generation = 15;
    var no_successor_root: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = .{ .device = identity.device, .inode = identity.inode +% 1 },
        .generation = 15,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer no_successor_root.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &no_successor_root));
    try expectIncomingRequestFailureForTest(&state, manifest_address);
}

test "repository transition accepted source closes inconsistent document owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 11));

    const bytes = try allocator.dupe(u8, "accepted source\n");
    var finished: repository_tasks.DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expectEqualStrings("accepted source\n", state.currentSource().?.bytes);
}

test "repository page owns reload state transitions" {
    var state: RepositoryPageState = .{};
    state.activate(1, null);
    state.requestReload(false);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
    try std.testing.expect(!state.needs_revalidation);
    try std.testing.expectEqualStrings("Repository required", state.status.text());

    state.requestReload(true);
    try std.testing.expect(state.needs_revalidation);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try std.testing.expectEqual(LoadState.failed, state.load_state);
    try std.testing.expect(std.mem.indexOf(u8, state.status.text(), "OutOfMemory") != null);
}
