const std = @import("std");
const builtin = @import("builtin");
const diff_parser = @import("../diff/parser.zig");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const diff_presentation_identity = @import("../diff/presentation_identity.zig");
const diff_syntax_view = @import("../diff/syntax_view.zig");
const diff_view_model = @import("../diff/view_model.zig");
const content_fingerprint = @import("../content_fingerprint.zig");
const repository_source = @import("../repository/source.zig");
const root_capability = @import("../repo/root_capability.zig");
const source_syntax = @import("../syntax/source.zig");
const source_syntax_runtime = @import("../syntax/source_runtime.zig");
const syntax_style = @import("../syntax/style.zig");
const app_load = @import("load.zig");
const page = @import("page.zig");
const projection_component = @import("projection_component.zig");
const review_read_epoch = @import("review_read_epoch.zig");

pub const max_generated_file_bytes = 1024 * 1024;
pub const max_cached_entries = 4;
pub const max_cached_retained_bytes = 32 * 1024 * 1024;

pub const Kind = enum {
    cached_diff,
    generated_added_file,
    combined_hunks,
};

pub const SourceKind = enum {
    unstaged,
    cached,
    other,
};

pub const ExpectedPresentationOwner = enum {
    combined_projection,
    primary_loaded,
};

/// Scalar-only hint naming the normalized presentation visible when a combined
/// refresh request was prepared. `owner` distinguishes an owned combined
/// projection from the independently owned primary load session. The
/// fingerprint may select the worker reuse path but is never acceptance proof;
/// the opaque token lets App verify that the same live owner still exists
/// before performing an exact comparison.
pub const ExpectedPresentation = struct {
    owner: ExpectedPresentationOwner = .combined_projection,
    fingerprint: diff_presentation_identity.Fingerprint,
    content_token: diff_presentation_identity.ContentToken,

    pub fn eql(self: ExpectedPresentation, other: ExpectedPresentation) bool {
        return self.owner == other.owner and
            self.fingerprint.eql(other.fingerprint) and
            self.content_token.eql(other.content_token);
    }
};

pub const Request = struct {
    identity: page.RequestIdentity,
    id: u64,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
    repo_root: []u8,
    path_key: []u8,
    kind: Kind,
    source_kind: SourceKind,
    source_session_revision: u64,
    status_snapshot_revision: u64,
    root_identity: ?root_capability.Identity = null,
    expected_presentation: ?ExpectedPresentation = null,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }

    pub fn matchesBorrowed(self: Request, read_epoch: review_read_epoch.ReviewRepositoryReadEpoch, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        return self.read_epoch.eql(read_epoch) and
            self.kind == kind and
            self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            self.status_snapshot_revision == status_snapshot_revision and
            std.mem.eql(u8, self.repo_root, repo_root) and
            std.mem.eql(u8, self.path_key, path_key);
    }

    /// Matches the retained visual owner only. A mutation may advance the read
    /// epoch while this body remains on screen as an inert snapshot, so callers
    /// which need current action/cache authority must use `matchesBorrowed`.
    pub fn matchesDisplayIdentity(self: Request, repo_root: []const u8, path_key: []const u8, source_kind: SourceKind, source_session_revision: u64) bool {
        return self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            std.mem.eql(u8, self.repo_root, repo_root) and
            std.mem.eql(u8, self.path_key, path_key);
    }

    pub fn sameSemanticKey(self: Request, other: Request) bool {
        // The expected presentation only chooses how a fresh generation is
        // constructed. It is not part of cache/action validity; the status
        // revision and the accepted Ready value remain authoritative.
        return optionalRootIdentityEql(self.root_identity, other.root_identity) and self.matchesBorrowed(
            other.read_epoch,
            other.repo_root,
            other.path_key,
            other.kind,
            other.source_kind,
            other.source_session_revision,
            other.status_snapshot_revision,
        );
    }

    pub fn matchesAuthority(self: Request, read_epoch: review_read_epoch.ReviewRepositoryReadEpoch, repo_root: []const u8, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        return self.read_epoch.eql(read_epoch) and
            self.source_kind == source_kind and
            self.source_session_revision == source_session_revision and
            self.status_snapshot_revision == status_snapshot_revision and
            std.mem.eql(u8, self.repo_root, repo_root);
    }

    pub fn matchesRootIdentity(self: Request, expected: ?root_capability.Identity) bool {
        return optionalRootIdentityEql(self.root_identity, expected);
    }
};

pub const TerminalPlainReason = enum {
    provider_disabled,
    provider_unavailable,
    snapshot_changed,
};

pub const GeneratedDecoration = union(enum) {
    eligible,
    terminal_plain: TerminalPlainReason,
    decorated: struct {
        spans: source_syntax.SourceSpans,
        has_visible_syntax: bool,
    },

    pub fn deinit(self: *GeneratedDecoration, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .decorated => |*decorated| decorated.spans.deinit(allocator),
            .eligible, .terminal_plain => {},
        }
        self.* = undefined;
    }

    pub fn retainedBytes(self: GeneratedDecoration) usize {
        return switch (self) {
            .decorated => |decorated| decorated.spans.retainedBytes(),
            .eligible, .terminal_plain => 0,
        };
    }

    pub fn lineSpans(self: GeneratedDecoration, line_index: usize) @import("../syntax/token.zig").LineSpans {
        return switch (self) {
            .decorated => |decorated| decorated.spans.lineSpans(line_index),
            .eligible, .terminal_plain => .empty(),
        };
    }

    pub fn hasVisibleSyntax(self: GeneratedDecoration) bool {
        return switch (self) {
            .decorated => |decorated| decorated.has_visible_syntax,
            .eligible, .terminal_plain => false,
        };
    }
};

pub const GeneratedFileBundle = struct {
    path: []u8,
    source: repository_source.Document,
    decoration: GeneratedDecoration,

    pub fn deinit(self: *GeneratedFileBundle, allocator: std.mem.Allocator) void {
        self.decoration.deinit(allocator);
        self.source.deinit(allocator);
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn retainedBytes(self: *const GeneratedFileBundle) usize {
        return self.path.len +| self.source.retainedBytes() +| self.decoration.retainedBytes();
    }

    pub fn fingerprint(self: *const GeneratedFileBundle) content_fingerprint.Fingerprint {
        return self.source.fingerprint;
    }
};

/// Stable rendered A-to-C content. Its normalized file, rendered indexes,
/// syntax-origin map, and decorated component backing are one lifetime and may
/// later be retained while index authority is replaced.
pub const CombinedPresentation = struct {
    arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Presentation,
    cached_bundle: app_load.LoadedDiffBundle,
    unstaged_bundle: app_load.LoadedDiffBundle,
    fingerprint: diff_presentation_identity.Fingerprint,
    content_token: diff_presentation_identity.ContentToken,

    /// Borrows origin and token storage owned by this presentation generation
    /// for one render call. The returned view has no cleanup and must not
    /// outlive `self`.
    fn syntaxView(self: *const CombinedPresentation) diff_syntax_view.View {
        return .initCombined(
            self.projection.presentation_syntax_origins,
            &self.cached_bundle.loaded.syntax_spans,
            &self.unstaged_bundle.loaded.syntax_spans,
        );
    }

    fn retainedBytes(self: *const CombinedPresentation) usize {
        return saturatedSum(&.{
            arenaCapacity(self.arena),
            arenaCapacity(self.cached_bundle.arena),
            arenaCapacity(self.unstaged_bundle.arena),
        });
    }

    fn deinit(self: *CombinedPresentation) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.cached_bundle.deinit();
        self.unstaged_bundle.deinit();
        self.projection = undefined;
    }
};

/// Fresh index-derived facts which alone authorize the next stage/unstage
/// patch. Parse-only component owners intentionally do not borrow storage from
/// `CombinedPresentation`.
pub const CombinedAuthority = struct {
    arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Authority,
    cached_component: projection_component.ParsedComponent,
    unstaged_component: projection_component.ParsedComponent,
    status_snapshot_revision: u64,

    pub fn actionSourceFile(self: *const CombinedAuthority, origin: diff_hunk_projection.HunkActionOrigin) ?diff_parser.FileDiff {
        const document = switch (origin) {
            .cached => self.cached_component.document,
            .unstaged => self.unstaged_component.document,
        };
        if (document.files.len != 1) return null;
        return document.files[0];
    }

    fn retainedBytes(self: *const CombinedAuthority) usize {
        return saturatedSum(&.{
            arenaCapacity(self.arena),
            arenaCapacity(self.cached_component.arena),
            arenaCapacity(self.unstaged_component.arena),
        });
    }

    pub fn deinit(self: *CombinedAuthority) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.cached_component.deinit();
        self.unstaged_component.deinit();
        self.projection = undefined;
    }
};

/// Fresh authority for a file whose index now contains every displayed hunk.
///
/// This is deliberately not represented as a `CombinedAuthority` with an
/// empty unstaged component. A staged-only generation has one real patch
/// source and every displayed hunk maps directly to that cached component;
/// keeping the shape explicit prevents a later action from treating a
/// fabricated component as Git authority.
pub const StagedOnlyAuthority = struct {
    projection: diff_hunk_projection.Authority,
    cached_component: projection_component.ParsedComponent,
    status_snapshot_revision: u64,

    pub fn actionSourceFile(self: *const StagedOnlyAuthority, origin: diff_hunk_projection.HunkActionOrigin) ?diff_parser.FileDiff {
        switch (origin) {
            .cached => {},
            .unstaged => return null,
        }
        if (self.cached_component.document.files.len != 1) return null;
        return self.cached_component.document.files[0];
    }

    fn retainedBytes(self: *const StagedOnlyAuthority) usize {
        return arenaCapacity(self.cached_component.arena);
    }

    pub fn deinit(self: *StagedOnlyAuthority) void {
        self.cached_component.deinit();
        self.projection = undefined;
    }
};

/// Provider-independent normalized candidate plus the fresh index authority
/// built from the same cached/unstaged component generation.
///
/// Candidate hunk text borrows from `fresh_authority`'s parsed components, so
/// both owners travel together until App has performed its exact comparison.
/// The candidate arena remains separate because a successful reuse discards
/// the candidate while transferring only fresh authority into the retained
/// presentation. No decorated bundle or syntax-provider storage belongs here.
pub const CombinedReuseCandidate = struct {
    candidate_arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Presentation,
    fingerprint: diff_presentation_identity.Fingerprint,
    fresh_authority: ?CombinedAuthority,

    pub fn displayFile(self: *const CombinedReuseCandidate) diff_parser.FileDiff {
        return self.projection.file;
    }

    pub fn retainedBytes(self: *const CombinedReuseCandidate) usize {
        return saturatedSum(&.{
            arenaCapacity(self.candidate_arena),
            if (self.fresh_authority) |authority| authority.retainedBytes() else 0,
        });
    }

    /// Consume the candidate presentation after exact acceptance and transfer
    /// the only remaining owner. Calling `deinit` afterwards is safe.
    pub fn discardCandidateAndTakeAuthority(self: *CombinedReuseCandidate) CombinedAuthority {
        if (self.candidate_arena) |*arena| arena.deinit();
        self.candidate_arena = null;
        self.projection = undefined;
        const authority = self.fresh_authority.?;
        self.fresh_authority = null;
        return authority;
    }

    pub fn deinit(self: *CombinedReuseCandidate) void {
        if (self.candidate_arena) |*arena| arena.deinit();
        self.candidate_arena = null;
        if (self.fresh_authority) |*authority| authority.deinit();
        self.fresh_authority = null;
        self.projection = undefined;
    }
};

/// Provider-independent cached-only candidate used at the
/// combined-to-staged-only boundary. Its parsed component is both the exact
/// comparison basis and the fresh source for a subsequent unstage action.
/// No decorated syntax storage is created unless reuse is rejected.
pub const StagedOnlyReuseCandidate = struct {
    fingerprint: diff_presentation_identity.Fingerprint,
    fresh_authority: ?StagedOnlyAuthority,

    pub fn displayFile(self: *const StagedOnlyReuseCandidate) diff_parser.FileDiff {
        return self.fresh_authority.?.cached_component.document.files[0];
    }

    pub fn retainedBytes(self: *const StagedOnlyReuseCandidate) usize {
        return if (self.fresh_authority) |authority| authority.retainedBytes() else 0;
    }

    pub fn takeAuthority(self: *StagedOnlyReuseCandidate) StagedOnlyAuthority {
        const authority = self.fresh_authority.?;
        self.fresh_authority = null;
        return authority;
    }

    pub fn deinit(self: *StagedOnlyReuseCandidate) void {
        if (self.fresh_authority) |*authority| authority.deinit();
        self.fresh_authority = null;
    }
};

pub const CombinedHunkBundle = struct {
    presentation: CombinedPresentation,
    authority: CombinedAuthority,

    pub fn displayFile(self: *const CombinedHunkBundle) diff_parser.FileDiff {
        return self.presentation.projection.file;
    }

    pub fn displayLineIndex(self: *const CombinedHunkBundle, mode: diff_view_model.DisplayMode) diff_view_model.RenderedLineIndex {
        return self.presentation.projection.lineIndex(mode);
    }

    pub fn hunkStageStates(self: *const CombinedHunkBundle) []const diff_hunk_projection.HunkStageState {
        return self.authority.projection.hunk_stage_states;
    }

    pub fn hunkActionOrigins(self: *const CombinedHunkBundle) []const diff_hunk_projection.HunkActionOrigin {
        return self.authority.projection.hunk_action_origins;
    }

    pub fn actionSourceFile(self: *const CombinedHunkBundle, origin: diff_hunk_projection.HunkActionOrigin) ?diff_parser.FileDiff {
        return self.authority.actionSourceFile(origin);
    }

    pub fn syntaxView(self: *const CombinedHunkBundle) diff_syntax_view.View {
        return self.presentation.syntaxView();
    }

    pub fn retainedBytes(self: *const CombinedHunkBundle) usize {
        return saturatedSum(&.{
            self.presentation.retainedBytes(),
            self.authority.retainedBytes(),
        });
    }

    pub fn deinit(self: *CombinedHunkBundle) void {
        self.presentation.deinit();
        self.authority.deinit();
        self.* = undefined;
    }
};

/// An exactly retained combined presentation paired with fresh staged-only
/// action authority. The request kind is `cached_diff`, but presentation
/// syntax and line indexes remain owned by the earlier combined generation.
pub const RetainedStagedOnlyBundle = struct {
    presentation: CombinedPresentation,
    authority: StagedOnlyAuthority,

    pub fn displayFile(self: *const RetainedStagedOnlyBundle) diff_parser.FileDiff {
        return self.presentation.projection.file;
    }

    pub fn displayLineIndex(self: *const RetainedStagedOnlyBundle, mode: diff_view_model.DisplayMode) diff_view_model.RenderedLineIndex {
        return self.presentation.projection.lineIndex(mode);
    }

    pub fn syntaxView(self: *const RetainedStagedOnlyBundle) diff_syntax_view.View {
        return self.presentation.syntaxView();
    }

    pub fn retainedBytes(self: *const RetainedStagedOnlyBundle) usize {
        return saturatedSum(&.{
            self.presentation.retainedBytes(),
            self.authority.retainedBytes(),
        });
    }

    pub fn deinit(self: *RetainedStagedOnlyBundle) void {
        self.presentation.deinit();
        self.authority.deinit();
        self.* = undefined;
    }
};

/// Owns both component snapshots when a mixed projection is intentionally
/// admitted as an inert body. Keeping this as a typed projection terminal
/// prevents navigation from falling through to an unrelated primary diff and
/// preserves the normal cache/defer/deinit ownership lifecycle.
pub const InertCombinedBundle = struct {
    cached_bundle: app_load.LoadedDiffBundle,
    unstaged_bundle: app_load.LoadedDiffBundle,

    pub fn deinit(self: *InertCombinedBundle) void {
        self.cached_bundle.deinit();
        self.unstaged_bundle.deinit();
        self.* = undefined;
    }
};

pub const StatusBody = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *StatusBody, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Ready = union(enum) {
    cached_diff: app_load.LoadedDiffBundle,
    generated_added_file: GeneratedFileBundle,
    combined_hunks: CombinedHunkBundle,
    /// Fresh mixed-index authority whose normalized presentation is exactly
    /// the immutable primary loaded file. The primary load session remains
    /// the presentation owner; this value owns no pointer into that session.
    primary_combined_authority: CombinedAuthority,
    /// Self-owned presentation retained across combined -> staged-only.
    retained_staged_only: RetainedStagedOnlyBundle,
    /// Fresh staged-only authority over an immutable primary presentation.
    /// Like the combined primary overlay, this never enters projection cache.
    primary_staged_only_authority: StagedOnlyAuthority,
    inert_combined: InertCombinedBundle,
    status_body: StatusBody,

    pub fn deinit(self: *Ready, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .cached_diff => |*bundle| bundle.deinit(),
            .generated_added_file => |*bundle| bundle.deinit(allocator),
            .combined_hunks => |*bundle| bundle.deinit(),
            .primary_combined_authority => |*authority| authority.deinit(),
            .retained_staged_only => |*bundle| bundle.deinit(),
            .primary_staged_only_authority => |*authority| authority.deinit(),
            .inert_combined => |*bundle| bundle.deinit(),
            .status_body => |*body| body.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn cacheable(self: Ready) bool {
        return switch (self) {
            .cached_diff, .generated_added_file, .combined_hunks, .retained_staged_only, .inert_combined => true,
            .primary_combined_authority, .primary_staged_only_authority, .status_body => false,
        };
    }

    fn retainedBytes(self: Ready) usize {
        return switch (self) {
            .cached_diff => |bundle| arenaCapacity(bundle.arena),
            .generated_added_file => |bundle| bundle.retainedBytes(),
            .combined_hunks => |bundle| bundle.retainedBytes(),
            .primary_combined_authority => |authority| authority.retainedBytes(),
            .retained_staged_only => |bundle| bundle.retainedBytes(),
            .primary_staged_only_authority => |authority| authority.retainedBytes(),
            .inert_combined => |bundle| saturatedSum(&.{
                arenaCapacity(bundle.cached_bundle.arena),
                arenaCapacity(bundle.unstaged_bundle.arena),
            }),
            .status_body => 0,
        };
    }
};

pub const TaskResult = union(enum) {
    ready: Ready,
    reuse_candidate: CombinedReuseCandidate,
    staged_only_reuse_candidate: StagedOnlyReuseCandidate,
    failed: StatusBody,
    failed_static: []const u8,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*ready| ready.deinit(allocator),
            .reuse_candidate => |*candidate| candidate.deinit(),
            .staged_only_reuse_candidate => |*candidate| candidate.deinit(),
            .failed => |*body| body.deinit(allocator),
            .failed_static => {},
        }
        self.* = undefined;
    }
};

pub const Finished = struct {
    request: Request,
    result: TaskResult,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub const GeneratedSyntaxRequest = struct {
    identity: page.RequestIdentity,
    id: u64,
    projection_id: u64,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
    root_identity: root_capability.Identity,
    repo_root: []u8,
    path_key: []u8,
    source_kind: SourceKind,
    source_session_revision: u64,
    status_snapshot_revision: u64,
    expected_fingerprint: content_fingerprint.Fingerprint,

    pub fn deinit(self: *GeneratedSyntaxRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }

    pub fn matches(self: GeneratedSyntaxRequest, other: GeneratedSyntaxRequest) bool {
        return self.id == other.id and
            self.projection_id == other.projection_id and
            self.read_epoch.eql(other.read_epoch) and
            self.identity.origin == other.identity.origin and
            self.identity.repo_epoch == other.identity.repo_epoch and
            self.identity.activation_id == other.identity.activation_id and
            self.root_identity.eql(other.root_identity) and
            self.source_kind == other.source_kind and
            self.source_session_revision == other.source_session_revision and
            self.status_snapshot_revision == other.status_snapshot_revision and
            self.expected_fingerprint.eql(other.expected_fingerprint) and
            std.mem.eql(u8, self.repo_root, other.repo_root) and
            std.mem.eql(u8, self.path_key, other.path_key);
    }
};

pub const GeneratedSyntaxResult = union(enum) {
    loaded: source_syntax.SourceSpans,
    terminal_plain: TerminalPlainReason,
    stale,

    pub fn deinit(self: *GeneratedSyntaxResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*spans| spans.deinit(allocator),
            .terminal_plain, .stale => {},
        }
        self.* = undefined;
    }
};

pub const GeneratedSyntaxFinished = struct {
    request: GeneratedSyntaxRequest,
    snapshot_fingerprint: ?content_fingerprint.Fingerprint,
    result: GeneratedSyntaxResult,

    pub fn deinit(self: *GeneratedSyntaxFinished, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadyDisplay = struct {
    request: Request,
    value: Ready,

    pub fn deinit(self: *ReadyDisplay, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.value.deinit(allocator);
        self.* = undefined;
    }

    fn retainedBytes(self: ReadyDisplay) usize {
        std.debug.assert(self.value.cacheable());
        return saturatedSum(&.{
            @sizeOf(CacheEntry),
            self.request.repo_root.len,
            self.request.path_key.len,
            self.value.retainedBytes(),
        });
    }
};

pub const Displayed = union(enum) {
    idle,
    ready: ReadyDisplay,
    failed: struct {
        request: Request,
        body: StatusBody,
    },

    pub fn deinit(self: *Displayed, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .idle => {},
            .ready => |*ready| ready.deinit(allocator),
            .failed => |*failed| {
                failed.request.deinit(allocator);
                failed.body.deinit(allocator);
            },
        }
        self.* = .idle;
    }

    pub fn request(self: *const Displayed) ?*const Request {
        return switch (self.*) {
            .idle => null,
            .ready => |*ready| &ready.request,
            .failed => |*failed| &failed.request,
        };
    }
};

const CacheEntry = struct {
    projection: ReadyDisplay,
    /// Measured once at admission. Cached projections are immutable, so this
    /// remains stable until promotion, invalidation, eviction, or deinit.
    retained_bytes: usize,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
        self.* = undefined;
    }
};

const Cache = struct {
    /// Oldest entry is at index zero; successful admission appends the MRU.
    entries: std.ArrayList(CacheEntry) = .empty,
    retained_bytes: usize = 0,

    fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    fn hasMatching(
        self: *const Cache,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) bool {
        return self.matchingIndex(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision) != null;
    }

    fn takeMatching(
        self: *Cache,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?ReadyDisplay {
        const index = self.matchingIndex(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision) orelse return null;
        var entry = self.entries.orderedRemove(index);
        self.retained_bytes -|= entry.retained_bytes;
        const projection = entry.projection;
        entry = undefined;
        return projection;
    }

    fn matchingIndex(
        self: *const Cache,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.projection.request.matchesBorrowed(
                read_epoch,
                repo_root,
                path_key,
                kind,
                source_kind,
                source_session_revision,
                status_snapshot_revision,
            )) return index;
        }
        return null;
    }

    fn admit(self: *Cache, allocator: std.mem.Allocator, projection: ReadyDisplay) void {
        self.admitWithLimits(allocator, projection, max_cached_entries, max_cached_retained_bytes);
    }

    fn admitWithLimits(
        self: *Cache,
        allocator: std.mem.Allocator,
        projection: ReadyDisplay,
        entry_limit: usize,
        byte_limit: usize,
    ) void {
        var candidate = projection;
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit(allocator);

        if (!candidate.value.cacheable() or entry_limit == 0) return;
        const retained_bytes = candidate.retainedBytes();
        if (retained_bytes > byte_limit) return;

        if (self.equalKeyIndex(candidate.request)) |index| self.evictAt(allocator, index);
        while (self.entries.items.len >= entry_limit or self.retained_bytes +| retained_bytes > byte_limit) {
            std.debug.assert(self.entries.items.len > 0);
            self.evictAt(allocator, 0);
        }

        self.entries.append(allocator, .{
            .projection = candidate,
            .retained_bytes = retained_bytes,
        }) catch return;
        self.retained_bytes += retained_bytes;
        candidate_owned = false;
    }

    fn equalKeyIndex(self: *const Cache, request: Request) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.projection.request.sameSemanticKey(request)) return index;
        }
        return null;
    }

    fn evictAt(self: *Cache, allocator: std.mem.Allocator, index: usize) void {
        var entry = self.entries.orderedRemove(index);
        self.retained_bytes -|= entry.retained_bytes;
        entry.deinit(allocator);
    }
};

pub const State = struct {
    displayed: Displayed = .idle,
    pending: ?Request = null,
    /// One exact-reuse rejection may request a single eager reconstruction of
    /// the same live presentation. Keeping only scalar presentation identity
    /// makes the retry independent of task/request allocation and lets a
    /// changed target invalidate it without retaining page-owned storage.
    eager_retry_basis: ?ExpectedPresentation = null,
    syntax_pending: ?GeneratedSyntaxRequest = null,
    syntax_next_id: u64 = 0,
    cache: Cache = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearPending(allocator);
        self.eager_retry_basis = null;
        self.clearSyntaxPending(allocator);
        self.displayed.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn clearPending(self: *State, allocator: std.mem.Allocator) void {
        if (self.pending) |*request| request.deinit(allocator);
        self.pending = null;
    }

    pub fn scheduleEagerRetry(self: *State, basis: ExpectedPresentation) void {
        self.eager_retry_basis = basis;
    }

    /// Returns whether the next request for `live` must omit its reuse hint.
    /// A different or absent live presentation consumes the stale retry
    /// marker instead of letting it affect another file/session.
    pub fn shouldForceEagerRetry(self: *State, live: ?ExpectedPresentation) bool {
        const retry = self.eager_retry_basis orelse return false;
        const current = live orelse {
            self.eager_retry_basis = null;
            return false;
        };
        if (!retry.eql(current)) {
            self.eager_retry_basis = null;
            return false;
        }
        return true;
    }

    pub fn finishEagerRetry(self: *State) void {
        self.eager_retry_basis = null;
    }

    pub fn clearDisplayed(self: *State, allocator: std.mem.Allocator) void {
        self.eager_retry_basis = null;
        self.clearSyntaxPending(allocator);
        self.displayed.deinit(allocator);
    }

    /// Accepted all-unstaged status makes the independently owned primary load
    /// authoritative again. A self-owned
    /// combined value releases presentation plus authority; a primary-backed
    /// value releases only its authority overlay. The primary load itself is
    /// deliberately outside this state and is never moved or deinitialized.
    pub fn finishCombinedToOrdinaryPrimary(self: *State, allocator: std.mem.Allocator) void {
        const ready = switch (self.displayed) {
            .ready => |*ready| ready,
            .idle, .failed => unreachable,
        };
        switch (ready.value) {
            .combined_hunks, .primary_combined_authority => {},
            else => unreachable,
        }
        self.clearDisplayed(allocator);
    }

    pub fn clearSyntaxPending(self: *State, allocator: std.mem.Allocator) void {
        if (self.syntax_pending) |*request| request.deinit(allocator);
        self.syntax_pending = null;
    }

    pub fn clearCache(self: *State, allocator: std.mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    pub fn isEmpty(self: *const State) bool {
        return self.pending == null and self.eager_retry_basis == null and self.syntax_pending == null and self.displayed.request() == null and self.cache.entries.items.len == 0;
    }

    pub fn cacheLen(self: *const State) usize {
        return self.cache.entries.items.len;
    }

    pub fn cacheRetainedBytes(self: *const State) usize {
        return self.cache.retained_bytes;
    }

    pub fn cacheHas(
        self: *const State,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) bool {
        return self.cache.hasMatching(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    pub fn takeCached(
        self: *State,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) ?ReadyDisplay {
        return self.cache.takeMatching(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    /// Moves the current display to the bounded cache only when it remains
    /// reusable under the current Review authority. Failed/status displays and
    /// old-revision values are deinitialized instead.
    pub fn cacheOrClearDisplayed(
        self: *State,
        allocator: std.mem.Allocator,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
        repo_root: []const u8,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) void {
        self.eager_retry_basis = null;
        self.clearSyntaxPending(allocator);
        var previous = self.displayed;
        self.displayed = .idle;
        switch (previous) {
            .idle => {},
            .ready => |ready| {
                if (ready.request.matchesAuthority(read_epoch, repo_root, source_kind, source_session_revision, status_snapshot_revision)) {
                    self.cache.admit(allocator, ready);
                } else {
                    var owned = ready;
                    owned.deinit(allocator);
                }
            },
            .failed => |*failed| {
                failed.request.deinit(allocator);
                failed.body.deinit(allocator);
            },
        }
        previous = undefined;
    }

    pub fn installReady(self: *State, ready: ReadyDisplay) void {
        std.debug.assert(switch (self.displayed) {
            .idle => true,
            else => false,
        });
        self.displayed = .{ .ready = ready };
    }

    /// Retain the currently displayed combined presentation while replacing
    /// its request and index authority with an exactly accepted candidate.
    /// All fallible admission work must finish before this no-fail move.
    pub fn installCombinedReuse(
        self: *State,
        allocator: std.mem.Allocator,
        request: Request,
        candidate: *CombinedReuseCandidate,
    ) void {
        std.debug.assert(request.kind == .combined_hunks);
        self.clearSyntaxPending(allocator);
        const ready = switch (self.displayed) {
            .ready => |*ready| ready,
            else => unreachable,
        };
        const bundle = switch (ready.value) {
            .combined_hunks => |*bundle| bundle,
            else => unreachable,
        };

        var old_authority = bundle.authority;
        bundle.authority = candidate.discardCandidateAndTakeAuthority();
        old_authority.deinit();
        ready.request.deinit(allocator);
        ready.request = request;
    }

    /// Move a self-owned presentation back from staged-only to combined after
    /// one hunk is unstaged. Only the cached-only authority is destroyed; the
    /// normalized file, syntax backing, rendered indexes, and content token
    /// remain the exact presentation admitted by App.
    pub fn installCombinedFromRetainedStagedOnlyReuse(
        self: *State,
        allocator: std.mem.Allocator,
        request: Request,
        candidate: *CombinedReuseCandidate,
    ) void {
        std.debug.assert(request.kind == .combined_hunks);
        self.clearSyntaxPending(allocator);
        const ready = switch (self.displayed) {
            .ready => |*ready| ready,
            else => unreachable,
        };
        const bundle = switch (ready.value) {
            .retained_staged_only => |*bundle| bundle,
            else => unreachable,
        };

        const presentation = bundle.presentation;
        bundle.authority.deinit();
        bundle.* = undefined;
        ready.value = .{ .combined_hunks = .{
            .presentation = presentation,
            .authority = candidate.discardCandidateAndTakeAuthority(),
        } };
        ready.request.deinit(allocator);
        ready.request = request;
    }

    /// Keep the independently owned primary load session as presentation and
    /// install only the exactly matched candidate's fresh index authority.
    /// A prior authority overlay is consumed here; it is deliberately never
    /// admitted to the projection cache because it cannot outlive its primary
    /// source-session owner.
    pub fn installPrimaryCombinedReuse(
        self: *State,
        allocator: std.mem.Allocator,
        request: Request,
        candidate: *CombinedReuseCandidate,
    ) void {
        std.debug.assert(request.kind == .combined_hunks);
        self.clearSyntaxPending(allocator);

        var previous = self.displayed;
        self.displayed = .idle;
        previous.deinit(allocator);
        self.displayed = .{ .ready = .{
            .request = request,
            .value = .{ .primary_combined_authority = candidate.discardCandidateAndTakeAuthority() },
        } };
    }

    /// Move an exactly equal, self-owned combined presentation into its
    /// staged-only generation while replacing the obsolete split authority
    /// with the candidate's cached-only authority. This is an infallible move
    /// performed only after App-side exact admission has succeeded.
    pub fn installRetainedStagedOnlyReuse(
        self: *State,
        allocator: std.mem.Allocator,
        request: Request,
        candidate: *StagedOnlyReuseCandidate,
    ) void {
        std.debug.assert(request.kind == .cached_diff);
        self.clearSyntaxPending(allocator);
        const ready = switch (self.displayed) {
            .ready => |*ready| ready,
            else => unreachable,
        };
        const bundle = switch (ready.value) {
            .combined_hunks => |*bundle| bundle,
            else => unreachable,
        };

        const presentation = bundle.presentation;
        bundle.authority.deinit();
        bundle.* = undefined;
        ready.value = .{ .retained_staged_only = .{
            .presentation = presentation,
            .authority = candidate.takeAuthority(),
        } };
        ready.request.deinit(allocator);
        ready.request = request;
    }

    /// Keep the immutable primary load as presentation owner while replacing
    /// its mixed authority overlay with fresh staged-only authority.
    pub fn installPrimaryStagedOnlyReuse(
        self: *State,
        allocator: std.mem.Allocator,
        request: Request,
        candidate: *StagedOnlyReuseCandidate,
    ) void {
        std.debug.assert(request.kind == .cached_diff);
        self.clearSyntaxPending(allocator);

        var previous = self.displayed;
        self.displayed = .idle;
        previous.deinit(allocator);
        self.displayed = .{ .ready = .{
            .request = request,
            .value = .{ .primary_staged_only_authority = candidate.takeAuthority() },
        } };
    }

    pub fn hasPending(self: State) bool {
        return self.pending != null;
    }

    pub fn hasSyntaxPending(self: State) bool {
        return self.syntax_pending != null;
    }

    pub fn hasDisplayed(self: *const State) bool {
        return self.displayed.request() != null;
    }

    pub fn pendingMatches(self: State, read_epoch: review_read_epoch.ReviewRepositoryReadEpoch, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        const request = self.pending orelse return false;
        return request.matchesBorrowed(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }

    pub fn displayedMatches(self: *const State, read_epoch: review_read_epoch.ReviewRepositoryReadEpoch, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, source_session_revision: u64, status_snapshot_revision: u64) bool {
        const request = self.displayed.request() orelse return false;
        return request.matchesBorrowed(read_epoch, repo_root, path_key, kind, source_kind, source_session_revision, status_snapshot_revision);
    }
};

fn arenaCapacity(arena: ?std.heap.ArenaAllocator) usize {
    return if (arena) |owned| owned.queryCapacity() else 0;
}

fn saturatedSum(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total +|= value;
    return total;
}

fn optionalRootIdentityEql(left: ?root_capability.Identity, right: ?root_capability.Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

pub const RequestCloneOptions = struct {
    /// Production request preparation must provide the page-owned value.
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
    root_identity: ?root_capability.Identity = null,
    expected_presentation: ?ExpectedPresentation = null,
};

pub fn cloneRequestWithOptions(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    id: u64,
    repo_root: []const u8,
    path_key: []const u8,
    kind: Kind,
    source_kind: SourceKind,
    source_session_revision: u64,
    status_snapshot_revision: u64,
    options: RequestCloneOptions,
) !Request {
    const owned_root = try allocator.dupe(u8, repo_root);
    errdefer allocator.free(owned_root);
    const owned_path = try allocator.dupe(u8, path_key);
    return .{
        .identity = identity,
        .id = id,
        .read_epoch = options.read_epoch,
        .repo_root = owned_root,
        .path_key = owned_path,
        .kind = kind,
        .source_kind = source_kind,
        .source_session_revision = source_session_revision,
        .status_snapshot_revision = status_snapshot_revision,
        .root_identity = options.root_identity,
        .expected_presentation = options.expected_presentation,
    };
}

/// Test-only constructors for fixtures which do not exercise repository-read
/// authority. Production builds expose no constructor that can silently choose
/// the canonical initial epoch; they must use `cloneRequestWithOptions` and pass
/// the page-owned value explicitly.
pub const testing = if (builtin.is_test) struct {
    pub fn cloneRequest(
        allocator: std.mem.Allocator,
        identity: page.RequestIdentity,
        id: u64,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
    ) !Request {
        return cloneRequestWithRootIdentity(
            allocator,
            identity,
            id,
            repo_root,
            path_key,
            kind,
            source_kind,
            source_session_revision,
            status_snapshot_revision,
            null,
        );
    }

    pub fn cloneRequestWithRootIdentity(
        allocator: std.mem.Allocator,
        identity: page.RequestIdentity,
        id: u64,
        repo_root: []const u8,
        path_key: []const u8,
        kind: Kind,
        source_kind: SourceKind,
        source_session_revision: u64,
        status_snapshot_revision: u64,
        root_identity: ?root_capability.Identity,
    ) !Request {
        return cloneRequestWithOptions(
            allocator,
            identity,
            id,
            repo_root,
            path_key,
            kind,
            source_kind,
            source_session_revision,
            status_snapshot_revision,
            .{
                .read_epoch = .{},
                .root_identity = root_identity,
            },
        );
    }
} else struct {};

pub fn cloneGeneratedSyntaxRequest(
    allocator: std.mem.Allocator,
    request: GeneratedSyntaxRequest,
) !GeneratedSyntaxRequest {
    const owned_root = try allocator.dupe(u8, request.repo_root);
    errdefer allocator.free(owned_root);
    const owned_path = try allocator.dupe(u8, request.path_key);
    return .{
        .identity = request.identity,
        .id = request.id,
        .projection_id = request.projection_id,
        .read_epoch = request.read_epoch,
        .root_identity = request.root_identity,
        .repo_root = owned_root,
        .path_key = owned_path,
        .source_kind = request.source_kind,
        .source_session_revision = request.source_session_revision,
        .status_snapshot_revision = request.status_snapshot_revision,
        .expected_fingerprint = request.expected_fingerprint,
    };
}

pub fn generatedSyntaxRequestForProjection(
    allocator: std.mem.Allocator,
    id: u64,
    identity: page.RequestIdentity,
    projection: Request,
    fingerprint: content_fingerprint.Fingerprint,
) !GeneratedSyntaxRequest {
    const root_identity = projection.root_identity orelse return error.MissingRootIdentity;
    const owned_root = try allocator.dupe(u8, projection.repo_root);
    errdefer allocator.free(owned_root);
    const owned_path = try allocator.dupe(u8, projection.path_key);
    return .{
        .identity = identity,
        .id = id,
        .projection_id = projection.id,
        .read_epoch = projection.read_epoch,
        .root_identity = root_identity,
        .repo_root = owned_root,
        .path_key = owned_path,
        .source_kind = projection.source_kind,
        .source_session_revision = projection.source_session_revision,
        .status_snapshot_revision = projection.status_snapshot_revision,
        .expected_fingerprint = fingerprint,
    };
}

pub fn statusBodyAlloc(allocator: std.mem.Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) !StatusBody {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    return .{
        .path = owned_path,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    };
}

test "status body allocation rolls back path when message allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn allocate(allocator: std.mem.Allocator) !void {
            var body = try statusBodyAlloc(allocator, "src/a.zig", "load failed: {s}", .{"OutOfMemory"});
            defer body.deinit(allocator);
        }
    }.allocate, .{});
}

pub fn generatedFileFromOwnedContent(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []u8,
    fingerprint: content_fingerprint.Fingerprint,
) !GeneratedFileBundle {
    var content_owned = true;
    errdefer if (content_owned) allocator.free(content);
    const copied_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copied_path);
    var source = try repository_source.Document.initOwned(allocator, content, fingerprint);
    content_owned = false;
    errdefer source.deinit(allocator);
    return .{
        .path = copied_path,
        .source = source,
        .decoration = if (source_syntax_runtime.enabled)
            .eligible
        else
            .{ .terminal_plain = .provider_disabled },
    };
}

pub fn generatedFileFromContent(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !GeneratedFileBundle {
    const copied_content = try allocator.dupe(u8, content);
    return generatedFileFromOwnedContent(allocator, path, copied_content, .init(copied_content));
}

pub fn sourceSpansHaveVisibleSyntax(spans: source_syntax.SourceSpans) bool {
    for (spans.spans) |span| {
        if (syntax_style.changesForeground(span.role)) return true;
    }
    return false;
}

test "generated file owns the shared source line model" {
    var bundle = try generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\n");
    defer bundle.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/new.zig", bundle.path);
    try std.testing.expectEqual(@as(usize, 2), bundle.source.rowCount());
    try std.testing.expectEqualStrings("one", bundle.source.lineBody(0).?);
    try std.testing.expectEqualStrings("two", bundle.source.lineBody(1).?);
    if (source_syntax_runtime.enabled) {
        try std.testing.expect(bundle.decoration == .eligible);
    } else {
        try std.testing.expectEqual(TerminalPlainReason.provider_disabled, bundle.decoration.terminal_plain);
    }
}

test "generated decoration distinguishes terminal empty and visible outcomes" {
    const allocator = std.testing.allocator;
    var bundle = try generatedFileFromContent(allocator, "src/new.zig", "const value = 1;\n");
    defer bundle.deinit(allocator);

    bundle.decoration = .{ .terminal_plain = .provider_unavailable };
    try std.testing.expect(!bundle.decoration.hasVisibleSyntax());

    bundle.decoration = .{ .decorated = .{
        .spans = .empty(),
        .has_visible_syntax = false,
    } };
    try std.testing.expectEqual(@as(usize, 0), bundle.decoration.lineSpans(0).spans.len);

    const entries = try allocator.dupe(source_syntax.LineEntry, &.{.{
        .line_index = 0,
        .span_start = 0,
        .span_count = 1,
    }});
    const spans = try allocator.dupe(@import("../syntax/token.zig").TokenSpan, &.{.{
        .start = 0,
        .end = 5,
        .role = .keyword,
    }});
    bundle.decoration.deinit(allocator);
    bundle.decoration = .{ .decorated = .{
        .spans = .{ .line_entries = entries, .spans = spans },
        .has_visible_syntax = true,
    } };
    try std.testing.expect(bundle.decoration.hasVisibleSyntax());
    try std.testing.expectEqual(@as(usize, 1), bundle.decoration.lineSpans(0).spans.len);
    try std.testing.expect(sourceSpansHaveVisibleSyntax(bundle.decoration.decorated.spans));
    try std.testing.expect(bundle.retainedBytes() >= bundle.source.retainedBytes() + entries.len * @sizeOf(source_syntax.LineEntry) + spans.len * @sizeOf(@import("../syntax/token.zig").TokenSpan));
}

test "projection read epoch participates in request semantic identity" {
    var request = try cloneRequestWithOptions(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "src/main.zig",
        .cached_diff,
        .unstaged,
        10,
        20,
        .{ .read_epoch = .{ .value = 31 } },
    );
    defer request.deinit(std.testing.allocator);

    const current: review_read_epoch.ReviewRepositoryReadEpoch = .{ .value = 31 };
    try std.testing.expect(request.matchesBorrowed(current, "/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20));
    try std.testing.expect(!request.matchesBorrowed(.{ .value = 32 }, "/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20));
    try std.testing.expect(request.matchesDisplayIdentity("/repo", "src/main.zig", .unstaged, 10));
    try std.testing.expect(!request.matchesBorrowed(current, "/repo", "src/main.zig", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(!request.matchesBorrowed(current, "/repo", "src/main.zig", .cached_diff, .cached, 10, 20));
    try std.testing.expect(!request.matchesBorrowed(current, "/repo", "src/main.zig", .cached_diff, .unstaged, 11, 20));
    try std.testing.expect(!request.matchesBorrowed(current, "/other", "src/main.zig", .cached_diff, .unstaged, 10, 20));
}

test "request clone owns paths and snapshots scalar presentation hint" {
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 7, .inode = 11 };
    const expected = ExpectedPresentation{
        .fingerprint = .{ .digest = [_]u8{0x5a} ** 32 },
        .content_token = .init(41),
    };
    var request = try cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.review(3, 5),
        9,
        "/repo",
        "src/a.zig",
        .combined_hunks,
        .unstaged,
        13,
        17,
        .{
            .read_epoch = .{ .value = 37 },
            .root_identity = root,
            .expected_presentation = expected,
        },
    );
    defer request.deinit(allocator);

    try std.testing.expect(request.matchesRootIdentity(root));
    try std.testing.expect(request.expected_presentation.?.eql(expected));

    var ordinary = try cloneRequestWithOptions(
        allocator,
        request.identity,
        10,
        request.repo_root,
        request.path_key,
        request.kind,
        request.source_kind,
        request.source_session_revision,
        request.status_snapshot_revision,
        .{
            .read_epoch = request.read_epoch,
            .root_identity = root,
        },
    );
    defer ordinary.deinit(allocator);
    try std.testing.expect(ordinary.expected_presentation == null);
    try std.testing.expect(request.sameSemanticKey(ordinary));

    ordinary.read_epoch = .{ .value = 38 };
    try std.testing.expect(!request.sameSemanticKey(ordinary));
}

test "eager retry basis is bounded to one live presentation identity" {
    const first: ExpectedPresentation = .{
        .fingerprint = .{ .digest = [_]u8{0x11} ** 32 },
        .content_token = .init(7),
    };
    const second: ExpectedPresentation = .{
        .fingerprint = .{ .digest = [_]u8{0x22} ** 32 },
        .content_token = .init(8),
    };
    const primary = ExpectedPresentation{
        .owner = .primary_loaded,
        .fingerprint = first.fingerprint,
        .content_token = first.content_token,
    };
    var state: State = .{};

    try std.testing.expect(!first.eql(primary));

    state.scheduleEagerRetry(first);
    try std.testing.expect(state.shouldForceEagerRetry(first));
    try std.testing.expect(state.eager_retry_basis != null);
    state.finishEagerRetry();
    try std.testing.expect(state.eager_retry_basis == null);

    state.scheduleEagerRetry(first);
    try std.testing.expect(!state.shouldForceEagerRetry(second));
    try std.testing.expect(state.eager_retry_basis == null);

    state.scheduleEagerRetry(first);
    try std.testing.expect(!state.shouldForceEagerRetry(primary));
    try std.testing.expect(state.eager_retry_basis == null);

    state.scheduleEagerRetry(first);
    try std.testing.expect(!state.shouldForceEagerRetry(null));
    try std.testing.expect(state.eager_retry_basis == null);
}

test "generated syntax request and clone retain projection read epoch" {
    const allocator = std.testing.allocator;
    const root = root_capability.Identity{ .device = 7, .inode = 11 };
    var projection = try cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.review(3, 5),
        9,
        "/repo",
        "src/new.zig",
        .generated_added_file,
        .unstaged,
        13,
        17,
        .{
            .read_epoch = .{ .value = 43 },
            .root_identity = root,
        },
    );
    defer projection.deinit(allocator);
    try std.testing.expect(projection.matchesRootIdentity(root));
    try std.testing.expect(!projection.matchesRootIdentity(.{ .device = 7, .inode = 12 }));

    var syntax_request = try generatedSyntaxRequestForProjection(allocator, 21, projection.identity, projection, .init("const x = 1;\n"));
    defer syntax_request.deinit(allocator);
    var cloned = try cloneGeneratedSyntaxRequest(allocator, syntax_request);
    defer cloned.deinit(allocator);
    try std.testing.expect(syntax_request.matches(cloned));
    try std.testing.expect(cloned.read_epoch.eql(.{ .value = 43 }));
    cloned.read_epoch = .{ .value = 44 };
    try std.testing.expect(!syntax_request.matches(cloned));
}

test "projection cache lookup requires matching read epoch" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    var projection = try testGeneratedProjection(allocator, 1, "a", 10, 20);
    projection.request.read_epoch = .{ .value = 47 };
    cache.admit(allocator, projection);
    projection = undefined;

    try std.testing.expect(!cache.hasMatching(.{}, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching(.{ .value = 47 }, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
}

test "projection read epoch fences pending display and cache admission" {
    const allocator = std.testing.allocator;
    const captured: review_read_epoch.ReviewRepositoryReadEpoch = .{ .value = 53 };
    const successor: review_read_epoch.ReviewRepositoryReadEpoch = .{ .value = 54 };
    var state: State = .{};
    defer state.deinit(allocator);

    state.pending = try cloneRequestWithOptions(
        allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        10,
        20,
        .{ .read_epoch = captured },
    );
    try std.testing.expect(state.pendingMatches(captured, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(!state.pendingMatches(successor, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    state.clearPending(allocator);

    var projection = try testGeneratedProjection(allocator, 2, "a", 10, 20);
    projection.request.read_epoch = captured;
    state.installReady(projection);
    projection = undefined;
    try std.testing.expect(state.displayedMatches(captured, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(!state.displayedMatches(successor, "/repo", "a", .generated_added_file, .unstaged, 10, 20));

    state.cacheOrClearDisplayed(allocator, successor, "/repo", .unstaged, 10, 20);
    try std.testing.expect(!state.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), state.cacheLen());
}

test "projection cache promotion re-admission and equal key replacement preserve LRU ownership" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    var a = try testGeneratedProjection(allocator, 1, "a", 10, 20);
    const a_lines = a.value.generated_added_file.source.bytes.ptr;
    cache.admitWithLimits(allocator, a, 2, max_cached_retained_bytes);
    a = undefined;
    var b = try testGeneratedProjection(allocator, 2, "b", 10, 20);
    cache.admitWithLimits(allocator, b, 2, max_cached_retained_bytes);
    b = undefined;

    var promoted_a = cache.takeMatching(.{}, "/repo", "a", .generated_added_file, .unstaged, 10, 20) orelse
        return error.ExpectedCacheHit;
    try std.testing.expectEqual(a_lines, promoted_a.value.generated_added_file.source.bytes.ptr);
    cache.admitWithLimits(allocator, promoted_a, 2, max_cached_retained_bytes);
    promoted_a = undefined;

    var c = try testGeneratedProjection(allocator, 3, "c", 10, 20);
    cache.admitWithLimits(allocator, c, 2, max_cached_retained_bytes);
    c = undefined;
    try std.testing.expect(!cache.hasMatching(.{}, "/repo", "b", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching(.{}, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching(.{}, "/repo", "c", .generated_added_file, .unstaged, 10, 20));

    var replacement_a = try testGeneratedProjection(allocator, 4, "a", 10, 20);
    const replacement_lines = replacement_a.value.generated_added_file.source.bytes.ptr;
    cache.admitWithLimits(allocator, replacement_a, 2, max_cached_retained_bytes);
    replacement_a = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    var final_a = cache.takeMatching(.{}, "/repo", "a", .generated_added_file, .unstaged, 10, 20) orelse
        return error.ExpectedReplacement;
    defer final_a.deinit(allocator);
    try std.testing.expectEqual(replacement_lines, final_a.value.generated_added_file.source.bytes.ptr);
}

test "projection cache enforces four entry and retained byte bounds" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    for (0..max_cached_entries + 1) |index| {
        var path_buffer: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "file-{d}", .{index});
        var projection = try testGeneratedProjection(allocator, index + 1, path, 10, 20);
        cache.admit(allocator, projection);
        projection = undefined;
    }
    try std.testing.expectEqual(max_cached_entries, cache.entries.items.len);
    try std.testing.expect(!cache.hasMatching(.{}, "/repo", "file-0", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.retained_bytes <= max_cached_retained_bytes);

    var oversized = try testGeneratedProjection(allocator, 20, "oversized", 10, 20);
    const retained_bytes = oversized.retainedBytes();
    cache.admitWithLimits(allocator, oversized, max_cached_entries, retained_bytes - 1);
    oversized = undefined;
    try std.testing.expect(!cache.hasMatching(.{}, "/repo", "oversized", .generated_added_file, .unstaged, 10, 20));
}

test "projection cache byte pressure evicts LRU below the entry limit" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    var a = try testGeneratedProjection(allocator, 1, "a", 10, 20);
    const a_bytes = a.retainedBytes();
    var b = try testGeneratedProjection(allocator, 2, "b", 10, 20);
    const b_bytes = b.retainedBytes();
    var c = try testGeneratedProjection(allocator, 3, "c", 10, 20);
    const byte_limit = a_bytes +| b_bytes;

    cache.admitWithLimits(allocator, a, max_cached_entries, byte_limit);
    a = undefined;
    cache.admitWithLimits(allocator, b, max_cached_entries, byte_limit);
    b = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);

    cache.admitWithLimits(allocator, c, max_cached_entries, byte_limit);
    c = undefined;
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expect(!cache.hasMatching(.{}, "/repo", "a", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching(.{}, "/repo", "b", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.hasMatching(.{}, "/repo", "c", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(cache.retained_bytes <= byte_limit);
}

test "projection cache rejects status body and cleans metadata allocation failure" {
    const allocator = std.testing.allocator;

    var cache: Cache = .{};
    defer cache.deinit(allocator);
    var status_projection = ReadyDisplay{
        .request = try testing.cloneRequest(allocator, page.RequestIdentity.review(0, 1), 1, "/repo", "status", .cached_diff, .unstaged, 10, 20),
        .value = .{ .status_body = try statusBodyAlloc(allocator, "status", "No staged diff.", .{}) },
    };
    cache.admit(allocator, status_projection);
    status_projection = undefined;
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);

    var projection = try testGeneratedProjection(allocator, 2, "oom", 10, 20);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cache.admit(failing.allocator(), projection);
    projection = undefined;
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);

    var state: State = .{};
    defer state.deinit(allocator);
    state.displayed = .{ .failed = .{
        .request = try testing.cloneRequest(allocator, page.RequestIdentity.review(0, 1), 3, "/repo", "failed", .cached_diff, .unstaged, 10, 20),
        .body = try statusBodyAlloc(allocator, "failed", "load failed", .{}),
    } };
    state.cacheOrClearDisplayed(allocator, .{}, "/repo", .unstaged, 10, 20);
    try std.testing.expect(!state.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), state.cacheLen());
}

test "projection cache retained bytes include every cacheable arena" {
    const allocator = std.testing.allocator;

    var cached_arena: std.heap.ArenaAllocator = .init(allocator);
    _ = try cached_arena.allocator().alloc(u8, 1024);
    const cached_capacity = cached_arena.queryCapacity();
    var cached = ReadyDisplay{
        .request = try testing.cloneRequest(allocator, page.RequestIdentity.review(0, 1), 1, "/repo", "cached", .cached_diff, .unstaged, 1, 2),
        .value = .{ .cached_diff = .{ .arena = cached_arena, .loaded = undefined } },
    };
    cached_arena = undefined;
    try std.testing.expect(cached.retainedBytes() >= cached_capacity);
    cached.deinit(allocator);

    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    var presentation_cached_arena: std.heap.ArenaAllocator = .init(allocator);
    var presentation_unstaged_arena: std.heap.ArenaAllocator = .init(allocator);
    var authority_cached_arena: std.heap.ArenaAllocator = .init(allocator);
    var authority_unstaged_arena: std.heap.ArenaAllocator = .init(allocator);
    _ = try presentation_arena.allocator().alloc(u8, 512);
    _ = try authority_arena.allocator().alloc(u8, 256);
    _ = try presentation_cached_arena.allocator().alloc(u8, 1024);
    _ = try presentation_unstaged_arena.allocator().alloc(u8, 2048);
    _ = try authority_cached_arena.allocator().alloc(u8, 4096);
    _ = try authority_unstaged_arena.allocator().alloc(u8, 8192);
    const combined_capacity = saturatedSum(&.{
        presentation_arena.queryCapacity(),
        authority_arena.queryCapacity(),
        presentation_cached_arena.queryCapacity(),
        presentation_unstaged_arena.queryCapacity(),
        authority_cached_arena.queryCapacity(),
        authority_unstaged_arena.queryCapacity(),
    });
    var combined = ReadyDisplay{
        .request = try testing.cloneRequest(allocator, page.RequestIdentity.review(0, 1), 2, "/repo", "combined", .combined_hunks, .unstaged, 1, 2),
        .value = .{ .combined_hunks = .{
            .presentation = .{
                .arena = presentation_arena,
                .projection = undefined,
                .cached_bundle = .{ .arena = presentation_cached_arena, .loaded = undefined },
                .unstaged_bundle = .{ .arena = presentation_unstaged_arena, .loaded = undefined },
                .fingerprint = undefined,
                .content_token = .init(2),
            },
            .authority = .{
                .arena = authority_arena,
                .projection = undefined,
                .cached_component = .{ .arena = authority_cached_arena, .text = undefined, .document = undefined, .file_text_eligibility = undefined, .fingerprint = .init("") },
                .unstaged_component = .{ .arena = authority_unstaged_arena, .text = undefined, .document = undefined, .file_text_eligibility = undefined, .fingerprint = .init("") },
                .status_snapshot_revision = 2,
            },
        } },
    };
    presentation_arena = undefined;
    authority_arena = undefined;
    presentation_cached_arena = undefined;
    presentation_unstaged_arena = undefined;
    authority_cached_arena = undefined;
    authority_unstaged_arena = undefined;
    try std.testing.expect(combined.retainedBytes() >= combined_capacity);
    combined.deinit(allocator);
}

fn testGeneratedProjection(
    allocator: std.mem.Allocator,
    id: usize,
    path: []const u8,
    source_session_revision: u64,
    status_snapshot_revision: u64,
) !ReadyDisplay {
    var request = try testing.cloneRequest(
        allocator,
        page.RequestIdentity.review(0, 1),
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
        .value = .{ .generated_added_file = try generatedFileFromContent(allocator, path, "one\ntwo\n") },
    };
}
