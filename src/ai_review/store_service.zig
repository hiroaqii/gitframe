//! Product application boundary for AI Review Store use cases.
//!
//! This is the only production module that combines Store authority with a
//! physical repository capability, Git object checks, or committed projection.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const config = @import("../config.zig");
const finding_projection = @import("finding_projection.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const repository_locator = @import("../git/repository_locator.zig");
const root_capability = @import("../repo/root_capability.zig");
const catalog_store = @import("../review_store/catalog.zig");
const core = @import("../review_store/core.zig");
const mutation_store = @import("../review_store/mutation.zig");
const store_name = @import("../review_store/name.zig");
const store_path = @import("../review_store/path.zig");
const run = @import("../review_store/run.zig");

const OpaqueStoreContext = opaque {};

pub const ConfigurationIdentity = struct {
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn eql(self: ConfigurationIdentity, other: ConfigurationIdentity) bool {
        return std.mem.eql(u8, &self.digest, &other.digest);
    }
};

const StoreContextState = struct {
    context: core.Context,
    identity: ConfigurationIdentity,
    configured: bool,
};

pub const max_namespace_entries = catalog_store.max_namespace_entries;
pub const max_run_candidates = catalog_store.max_run_candidates;
pub const max_enumerated_name_bytes = catalog_store.max_enumerated_name_bytes;
pub const max_diagnostics = catalog_store.max_diagnostics;
pub const max_diagnostic_bytes = catalog_store.max_diagnostic_bytes;

const BoundaryHook = struct {
    context: *anyopaque,
    before_final_check: *const fn (*anyopaque) void,

    fn fire(self: BoundaryHook) void {
        self.before_final_check(self.context);
    }
};

/// Owned configuration-only Store address. Construction performs no Store IO,
/// and no path, descriptor, registry, or root accessor is public.
pub const ConfiguredStore = struct {
    state: *OpaqueStoreContext,

    pub fn init(
        allocator: std.mem.Allocator,
        configured: ?[]const u8,
        environment: ?*const std.process.Environ.Map,
    ) !ConfiguredStore {
        var resolved = try store_path.resolveFromEnvironment(allocator, configured, environment);
        defer resolved.deinit(allocator);
        const state_ptr = try allocator.create(StoreContextState);
        errdefer allocator.destroy(state_ptr);
        state_ptr.* = .{
            .context = try core.Context.initResolved(allocator, &resolved),
            .identity = configurationIdentity(&resolved),
            .configured = resolved == .available,
        };
        return .{ .state = @ptrCast(state_ptr) };
    }

    pub fn initConfigured(
        allocator: std.mem.Allocator,
        configured: []const u8,
    ) !ConfiguredStore {
        try store_path.validateAbsoluteCanonical(configured);
        const state_ptr = try allocator.create(StoreContextState);
        errdefer allocator.destroy(state_ptr);
        state_ptr.* = .{
            .context = try core.Context.initConfigured(allocator, configured),
            .identity = configuredIdentity(configured),
            .configured = true,
        };
        return .{ .state = @ptrCast(state_ptr) };
    }

    pub fn clone(self: *const ConfiguredStore, allocator: std.mem.Allocator) std.mem.Allocator.Error!ConfiguredStore {
        const state_ptr = try allocator.create(StoreContextState);
        errdefer allocator.destroy(state_ptr);
        const source = self.contextState();
        state_ptr.* = .{
            .context = try source.context.clone(allocator),
            .identity = source.identity,
            .configured = source.configured,
        };
        return .{ .state = @ptrCast(state_ptr) };
    }

    pub fn deinit(self: *ConfiguredStore, allocator: std.mem.Allocator) void {
        const state_ptr = self.contextStateMut();
        state_ptr.context.deinit(allocator);
        allocator.destroy(state_ptr);
        self.* = undefined;
    }

    pub fn identity(self: *const ConfiguredStore) ConfigurationIdentity {
        return self.contextState().identity;
    }

    pub fn isConfigured(self: *const ConfiguredStore) bool {
        return self.contextState().configured;
    }

    fn context(self: *const ConfiguredStore) *const core.Context {
        return &self.contextState().context;
    }

    fn contextState(self: *const ConfiguredStore) *const StoreContextState {
        return @ptrCast(@alignCast(self.state));
    }

    fn contextStateMut(self: *ConfiguredStore) *StoreContextState {
        return @ptrCast(@alignCast(self.state));
    }
};

fn configurationIdentity(resolved: *const store_path.Resolved) ConfigurationIdentity {
    return switch (resolved.*) {
        .available => |value| configuredIdentity(value),
        .unavailable => |reason| blk: {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update("unavailable\x00");
            hasher.update(@tagName(reason));
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            hasher.final(&digest);
            break :blk .{ .digest = digest };
        },
    };
}

fn configuredIdentity(value: []const u8) ConfigurationIdentity {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("configured\x00");
    hasher.update(value);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return .{ .digest = digest };
}

/// Borrowed physical repository authority for one service call.
pub const RepositoryContext = struct {
    capability: *const root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,

    fn git(self: RepositoryContext) git_command.DirectoryContext {
        return .{ .cwd = self.capability.dir(), .environment = self.environment };
    }
};

pub const StoreSnapshot = catalog_store.StoreSnapshot;
pub const ArtifactSnapshot = run.ArtifactSnapshot;
pub const RunSummaryStatus = catalog_store.RunStatus;

pub const RunSummary = struct {
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    status: RunSummaryStatus,
    created_at: [20]u8,
    created_at_unix: i64,
    producer_name: []u8,
    producer_model: ?[]u8,
    base_label: ?[]u8,
    head_label: ?[]u8,
    finding_count: u32,
    availability: git_review.TargetAvailability,
    artifact_snapshot: ArtifactSnapshot,

    pub fn deinit(self: *RunSummary, allocator: std.mem.Allocator) void {
        if (self.head_label) |value| allocator.free(value);
        if (self.base_label) |value| allocator.free(value);
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }
};

pub const DiagnosticKind = catalog_store.DiagnosticKind;

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    text: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const History = struct {
    snapshot: StoreSnapshot,
    rows: []RunSummary,
    diagnostics: []Diagnostic,
    skipped_count: usize,
    orphan_count: usize,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const BoundEmpty = struct { snapshot: StoreSnapshot };

pub const ScanFailure = enum {
    repository_invalid,
    store_invalid,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    registry_invalid,
    registry_unavailable,
    namespace_invalid,
    enumeration_failed,
    scan_limit_exceeded,
    git_failed,
    identity_missing,
    identity_invalid,
    identity_unavailable,
    identity_conflict,
    identity_duplicate,
    binding_move_required,
};

pub const ScanResult = union(enum) {
    unbound,
    bound_empty: BoundEmpty,
    history: History,
    failure: ScanFailure,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .history => |*value| value.deinit(allocator),
            .unbound, .bound_empty, .failure => {},
        }
        self.* = .unbound;
    }
};

/// Resolve the repository binding, scan Store-only rows, then batch-check Git
/// object availability without retaining operation authority.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const ConfiguredStore,
    repository: RepositoryContext,
) std.mem.Allocator.Error!ScanResult {
    return scanWithHook(allocator, io, store, repository, null);
}

fn scanWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const ConfiguredStore,
    repository: RepositoryContext,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!ScanResult {
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .repository_invalid },
    };
    const instance_id = located.instanceId() orelse
        return .{ .failure = markerScanFailure(located.marker) };
    switch (try core.probeBinding(allocator, io, store.context(), located)) {
        .bound => {},
        .unbound => return .unbound,
        .failure => |failure| return .{ .failure = mapProbeScanFailure(failure) },
    }
    var scanned = try catalog_store.scan(allocator, io, store.context(), instance_id);
    defer scanned.deinit(allocator);
    const catalog_value = switch (scanned) {
        .unbound => return .unbound,
        .bound_empty => |value| {
            if (try finalScanFailure(allocator, io, store, repository, located, &scanned, hook)) |failure|
                return .{ .failure = failure };
            return .{ .bound_empty = .{ .snapshot = value.snapshot } };
        },
        .failure => |failure| return .{ .failure = mapCatalogScanFailure(failure) },
        .catalog => |*value| value,
    };

    var rows: std.ArrayList(RunSummary) = .empty;
    defer deinitRows(allocator, &rows);
    for (catalog_value.rows) |*row| {
        const summary = try summaryFromCatalogRow(allocator, row);
        rows.append(allocator, summary) catch |err| {
            var owned = summary;
            owned.deinit(allocator);
            return err;
        };
    }
    if (rows.items.len != 0) {
        const targets = try allocator.alloc(committed_review.CommittedReviewTarget, rows.items.len);
        defer allocator.free(targets);
        for (rows.items, 0..) |row, index| targets[index] = row.target;
        var availability = try git_review.checkTargetsAvailability(allocator, io, repository.git(), targets);
        defer availability.deinit(allocator);
        const values = switch (availability) {
            .available => |items| items,
            .failure => return .{ .failure = .git_failed },
        };
        for (rows.items, values) |*row, value| row.availability = value;
    }
    std.mem.sort(RunSummary, rows.items, {}, summaryLessThan);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &diagnostics);
    for (catalog_value.diagnostics) |diagnostic| {
        try appendDiagnostic(allocator, &diagnostics, diagnostic.kind, diagnostic.text);
    }
    if (try finalScanFailure(allocator, io, store, repository, located, &scanned, hook)) |failure|
        return .{ .failure = failure };
    const owned_rows = try rows.toOwnedSlice(allocator);
    errdefer {
        for (owned_rows) |*row| row.deinit(allocator);
        allocator.free(owned_rows);
    }
    const owned_diagnostics = try diagnostics.toOwnedSlice(allocator);
    errdefer {
        for (owned_diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(owned_diagnostics);
    }
    return .{ .history = .{
        .snapshot = catalog_value.snapshot,
        .rows = owned_rows,
        .diagnostics = owned_diagnostics,
        .skipped_count = catalog_value.skipped_count,
        .orphan_count = catalog_value.orphan_count,
    } };
}

fn finalScanFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *const repository_locator.LocatedRepository,
    expected: *const catalog_store.ScanResult,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!?ScanFailure {
    if (hook) |value| value.fire();
    located.revalidate(allocator, io, repository.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return markerErrorScanFailure(err);
    };
    switch (try core.probeBinding(allocator, io, store.context(), located)) {
        .bound => {},
        .unbound => return .identity_conflict,
        .failure => |failure| return mapProbeScanFailure(failure),
    }
    const instance_id = located.instanceId() orelse return .identity_missing;
    var current = try catalog_store.scan(allocator, io, store.context(), instance_id);
    defer current.deinit(allocator);
    return switch (current) {
        .failure => |failure| mapCatalogScanFailure(failure),
        .unbound => .identity_conflict,
        .bound_empty, .catalog => if (catalogScansEqual(expected, &current)) null else .identity_conflict,
    };
}

fn catalogScansEqual(expected: *const catalog_store.ScanResult, actual: *const catalog_store.ScanResult) bool {
    return switch (expected.*) {
        .bound_empty => |left| switch (actual.*) {
            .bound_empty => |right| left.snapshot.eql(right.snapshot),
            else => false,
        },
        .catalog => |left| switch (actual.*) {
            .catalog => |right| catalogValuesEqual(&left, &right),
            else => false,
        },
        else => false,
    };
}

fn catalogValuesEqual(left: *const catalog_store.Catalog, right: *const catalog_store.Catalog) bool {
    if (!left.snapshot.eql(right.snapshot) or
        left.rows.len != right.rows.len or
        left.diagnostics.len != right.diagnostics.len or
        left.skipped_count != right.skipped_count or
        left.orphan_count != right.orphan_count) return false;
    for (left.rows, right.rows) |left_row, right_row| {
        if (!left_row.review_id.eql(right_row.review_id) or
            !left_row.artifact_snapshot.eql(right_row.artifact_snapshot)) return false;
    }
    for (left.diagnostics, right.diagnostics) |left_diagnostic, right_diagnostic| {
        if (left_diagnostic.kind != right_diagnostic.kind or
            !std.mem.eql(u8, left_diagnostic.text, right_diagnostic.text)) return false;
    }
    return true;
}

pub const SelectionFailure = enum {
    repository_unavailable,
    root_drift,
    binding_drift,
    run_invalid,
    artifact_drift,
    target_unavailable,
    git_failed,
    projection_failed,
};

pub const SelectedRunRead = struct {
    snapshot: StoreSnapshot,
    artifacts: run.LoadedRunArtifacts,
    projection: git_review.CommittedDiffProjection,
    finding_projection: finding_projection.FindingProjectionIndex,

    pub fn deinit(self: *SelectedRunRead, allocator: std.mem.Allocator) void {
        self.finding_projection.deinit(allocator);
        self.projection.deinit(allocator);
        self.artifacts.deinit(allocator);
        self.* = undefined;
    }
};

pub const SelectionResult = union(enum) {
    selected: SelectedRunRead,
    failure: SelectionFailure,

    pub fn deinit(self: *SelectionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .selected => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .run_invalid };
    }
};

/// Revalidate one exact scanned identity, check its exact Git target, and
/// materialize the same committed projection. No scan or fallback is used.
pub fn selectExact(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: ArtifactSnapshot,
) std.mem.Allocator.Error!SelectionResult {
    return selectExactWithArtifactPolicy(
        allocator,
        io,
        configured_store,
        repository,
        expected,
        review_id,
        expected_artifacts,
        .strict,
        null,
    );
}

/// Reload the same exact pinned Run after a known mutable-artifact drift.
/// Store, repository, Run, manifest, and Findings identity remain pinned.
pub fn selectExactReload(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: ArtifactSnapshot,
) std.mem.Allocator.Error!SelectionResult {
    return selectExactWithArtifactPolicy(
        allocator,
        io,
        configured_store,
        repository,
        expected,
        review_id,
        expected_artifacts,
        .immutable,
        null,
    );
}

const SelectionArtifactPolicy = enum { strict, immutable };

fn selectExactWithArtifactPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: ArtifactSnapshot,
    artifact_policy: SelectionArtifactPolicy,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!SelectionResult {
    var owned_repository = repository.capability.duplicate() catch
        return .{ .failure = .repository_unavailable };
    defer owned_repository.deinit();
    var owned_environment = git_command.LocalGitEnvironment.initFromParent(
        allocator,
        repository.environment.borrow(),
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .repository_unavailable };
    };
    defer owned_environment.deinit();
    const owned_context: RepositoryContext = .{
        .capability = &owned_repository,
        .environment = &owned_environment,
    };

    var located_result = try repository_locator.locate(allocator, io, owned_context.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .repository_unavailable },
    };
    const instance_id = located.instanceId() orelse return .{ .failure = .binding_drift };
    if (!instance_id.eql(expected.repository_instance_id)) return .{ .failure = .binding_drift };

    var exact_result = try catalog_store.readExact(
        allocator,
        io,
        configured_store.context(),
        instance_id,
        review_id,
        expected,
        if (artifact_policy == .strict) expected_artifacts else null,
    );
    defer exact_result.deinit(allocator);
    const exact = switch (exact_result) {
        .exact => |*value| value,
        .absent => return .{ .failure = .run_invalid },
        .failure => |failure| return .{ .failure = mapExactSelectionFailure(failure) },
    };
    if (artifact_policy == .immutable and
        !immutableArtifactIdentityEql(exact.artifact_snapshot, expected_artifacts))
    {
        return .{ .failure = .artifact_drift };
    }

    const availability = try git_review.checkTargetAvailability(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
    );
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => return .{ .failure = .git_failed },
    }
    var source_result = try git_review.materializeCommittedFindingProjectionSource(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
    );
    defer source_result.deinit(allocator);
    const source = switch (source_result) {
        .source => |*value| value,
        .failure => return .{ .failure = .projection_failed },
    };

    const anchors = try allocator.alloc(committed_review.CodeAnchor, exact.artifacts.findings.value.findings.len);
    defer allocator.free(anchors);
    for (exact.artifacts.findings.value.findings, anchors) |finding, *anchor| anchor.* = finding.anchor;
    const validations = try git_review.validateCodeAnchors(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
        anchors,
    );
    defer allocator.free(validations);
    var finding_index = finding_projection.build(allocator, .{
        .expected_review_repository_id = expected.review_repository_id,
        .requested_review_id = review_id,
        .projection_target = exact.artifacts.manifest.value.target,
        .manifest = &exact.artifacts.manifest.value,
        .findings_bytes = exact.artifacts.findings_bytes,
        .finding_set = &exact.artifacts.findings.value,
        .projection = &source.projection,
        .endpoints = &source.endpoints,
        .anchor_validations = validations,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBinding, error.InvalidSource => return .{ .failure = .projection_failed },
    };
    errdefer finding_index.deinit(allocator);

    if (hook) |value| value.fire();
    located.revalidate(allocator, io, owned_context.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        finding_index.deinit(allocator);
        return .{ .failure = .binding_drift };
    };
    if (try exactStoreFailure(
        allocator,
        io,
        configured_store.context(),
        located,
        instance_id,
        review_id,
        &exact.snapshot,
        exact.artifact_snapshot,
    )) |failure| {
        finding_index.deinit(allocator);
        return .{ .failure = mapExactSelectionFailure(failure) };
    }

    const artifacts = exact.artifacts;
    const projection = source.projection;
    source.endpoints.deinit(allocator);
    source_result = .{ .failure = .projection_git_command_failed };
    exact.root.deinit();
    exact_result = .absent;
    return .{ .selected = .{
        .snapshot = expected,
        .artifacts = artifacts,
        .projection = projection,
        .finding_projection = finding_index,
    } };
}

fn immutableArtifactIdentityEql(actual: ArtifactSnapshot, expected: ArtifactSnapshot) bool {
    return actual.manifest_digest.eql(expected.manifest_digest) and
        actual.findings_digest.eql(expected.findings_digest) and
        if (actual.run_location) |actual_location|
            if (expected.run_location) |expected_location|
                actual_location.eql(expected_location)
            else
                false
        else
            expected.run_location == null;
}

fn exactStoreFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    located: *const repository_locator.LocatedRepository,
    instance_id: committed_review.RepositoryInstanceId,
    review_id: committed_review.ReviewId,
    expected_store: *const StoreSnapshot,
    expected_artifacts: ArtifactSnapshot,
) std.mem.Allocator.Error!?catalog_store.ReadFailure {
    var current = try catalog_store.readExact(
        allocator,
        io,
        context,
        instance_id,
        review_id,
        expected_store.*,
        expected_artifacts,
    );
    defer current.deinit(allocator);
    switch (current) {
        .exact => {},
        .absent => return .concurrent_conflict,
        .failure => |failure| return failure,
    }
    switch (try core.probeBinding(allocator, io, context, located)) {
        .bound => return null,
        .unbound, .failure => return .binding_changed,
    }
}

pub const ExpectedPublicationIdentity = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    target: committed_review.CommittedReviewTarget,
    producer: committed_review.Producer,
    created_at: []const u8,
    finding_count: u32,
    manifest_sha256: committed_review.Sha256Digest,
    findings_sha256: committed_review.Sha256Digest,
};

pub const PublicationIdentity = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    target: committed_review.CommittedReviewTarget,
    producer_name: []u8,
    producer_model: ?[]u8,
    producer_version: ?[]u8,
    producer_skill_version: ?[]u8,
    created_at: [20]u8,
    finding_count: u32,
    manifest_sha256: committed_review.Sha256Digest,
    findings_sha256: committed_review.Sha256Digest,

    pub fn deinit(self: *PublicationIdentity, allocator: std.mem.Allocator) void {
        if (self.producer_skill_version) |value| allocator.free(value);
        if (self.producer_version) |value| allocator.free(value);
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }
};

pub const Lifecycle = enum { published, draft, result };

pub const ExactIdentity = struct {
    review_id: committed_review.ReviewId,
    identity: PublicationIdentity,
    artifacts: ArtifactSnapshot,
    lifecycle: Lifecycle,

    pub fn deinit(self: *ExactIdentity, allocator: std.mem.Allocator) void {
        self.identity.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadFailure = enum {
    expected_mismatch,
    artifact_invalid,
    review_not_found,
    target_unavailable,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    repository_invalid,
    git_failed,
    store_invalid,
    binding_invalid,
    io_failed,
    root_changed,
    binding_changed,
    artifact_changed,
    concurrent_conflict,
    identity_missing,
    identity_invalid,
    identity_unavailable,
    identity_conflict,
    identity_duplicate,
    binding_move_required,
};

pub const ReadResult = union(enum) {
    exact: ExactIdentity,
    failure: ReadFailure,

    pub fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exact => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

pub const ResultIdentity = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    finding_count: u32,
    findings_sha256: committed_review.Sha256Digest,
};

pub const CompletedResult = struct {
    identity: ResultIdentity,
    result_sha256: committed_review.Sha256Digest,
    result_bytes: []u8,

    pub fn deinit(self: *CompletedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.result_bytes);
        self.* = undefined;
    }
};

pub const ExactResultRead = union(enum) {
    pending: ResultIdentity,
    completed: CompletedResult,
    failure: ReadFailure,

    pub fn deinit(self: *ExactResultRead, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |*value| value.deinit(allocator),
            .pending, .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

const AdmittedExactRun = union(enum) {
    exact: catalog_store.ExactRun,
    failure: ReadFailure,

    fn deinit(self: *AdmittedExactRun, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exact => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

/// Freshly resolve and admit one exact Run. This common operation never scans
/// a namespace and keeps the validated result bytes in the admitted snapshot.
fn admitExactRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!AdmittedExactRun {
    var repository = switch (try openRepository(allocator, io, environment_map, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = mapPublicationToReadFailure(failure) },
    };
    defer repository.deinit();

    var resolved = try resolveConfiguredStore(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const configured_store = switch (resolved) {
        .store => |*value| value,
        .failure => return .{ .failure = .store_invalid },
    };
    return admitExactRunLocated(allocator, io, configured_store, .{
        .capability = &repository.root,
        .environment = &repository.environment,
    }, &repository.located, review_id, expected);
}

fn admitExactRunLocated(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!AdmittedExactRun {
    return admitExactRunLocatedWithHook(
        allocator,
        io,
        configured_store,
        repository,
        located,
        review_id,
        expected,
        null,
    );
}

fn admitExactRunLocatedWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!AdmittedExactRun {
    const instance_id = located.instanceId() orelse
        return .{ .failure = markerReadFailure(located.marker) };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound => return .{ .failure = .review_not_found },
        .failure => |failure| return .{ .failure = probeReadFailure(failure) },
    }
    var exact_result = try catalog_store.readExact(
        allocator,
        io,
        configured_store.context(),
        instance_id,
        review_id,
        null,
        null,
    );
    defer exact_result.deinit(allocator);
    const exact = switch (exact_result) {
        .absent => return .{ .failure = .review_not_found },
        .failure => |failure| return .{ .failure = mapExactIdentityFailure(failure) },
        .exact => |*value| value,
    };

    const availability = try git_review.checkTargetAvailability(
        allocator,
        io,
        repository.git(),
        exact.artifacts.manifest.value.target,
    );
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => |failure| return .{ .failure = switch (failure) {
            .invalid_repository => .repository_invalid,
            .invalid_target => .artifact_invalid,
            else => .git_failed,
        } },
    }

    const manifest = &exact.artifacts.manifest.value;
    const artifacts = exact.artifact_snapshot;
    if (expected) |asserted| {
        if (!expectedIdentityMatches(asserted, manifest, artifacts)) {
            return .{ .failure = .expected_mismatch };
        }
    }
    if (hook) |value| value.fire();
    located.revalidate(allocator, io, repository.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = markerErrorReadFailure(err) };
    };
    if (try exactStoreFailure(
        allocator,
        io,
        configured_store.context(),
        located,
        instance_id,
        review_id,
        &exact.snapshot,
        exact.artifact_snapshot,
    )) |failure| return .{ .failure = mapExactIdentityFailure(failure) };
    const owned = exact.*;
    exact_result = .absent;
    return .{ .exact = owned };
}

/// Read one exact publication through retained repository and Store authority.
pub fn readExactIdentityWithRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!ReadResult {
    var located_result = try locateForPublication(allocator, io, repository);
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => |failure| return .{ .failure = mapPublicationToReadFailure(failure) },
    };
    var admitted = try admitExactRunLocated(
        allocator,
        io,
        configured_store,
        repository,
        located,
        review_id,
        expected,
    );
    defer admitted.deinit(allocator);
    return identityFromAdmitted(allocator, &admitted, review_id);
}

/// Generic no-write exact-ID use case. The compatibility result deliberately
/// exposes identity and lifecycle only, preserving `review-store-read` v1.
pub fn readExactIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!ReadResult {
    var admitted = try admitExactRun(
        allocator,
        io,
        environment_map,
        repository_path,
        review_id,
        expected,
    );
    defer admitted.deinit(allocator);
    return identityFromAdmitted(allocator, &admitted, review_id);
}

fn identityFromAdmitted(
    allocator: std.mem.Allocator,
    admitted: *AdmittedExactRun,
    review_id: committed_review.ReviewId,
) std.mem.Allocator.Error!ReadResult {
    const exact = switch (admitted.*) {
        .failure => |failure| return .{ .failure = failure },
        .exact => |*value| value,
    };
    return identityFromExact(allocator, exact, review_id);
}

fn identityFromExact(allocator: std.mem.Allocator, exact: *const catalog_store.ExactRun, review_id: committed_review.ReviewId) std.mem.Allocator.Error!ReadResult {
    const manifest = &exact.artifacts.manifest.value;
    const artifacts = exact.artifact_snapshot;
    const producer_name = try allocator.dupe(u8, manifest.producer.name);
    errdefer allocator.free(producer_name);
    const producer_model = if (manifest.producer.model) |value| try allocator.dupe(u8, value) else null;
    errdefer if (producer_model) |value| allocator.free(value);
    const producer_version = if (manifest.producer.version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (producer_version) |value| allocator.free(value);
    const producer_skill_version = if (manifest.producer.skill_version) |value| try allocator.dupe(u8, value) else null;
    errdefer if (producer_skill_version) |value| allocator.free(value);
    var created_at: [20]u8 = undefined;
    @memcpy(&created_at, manifest.created_at);
    return .{ .exact = .{
        .review_id = review_id,
        .identity = .{
            .review_repository_id = manifest.review_repository_id,
            .target = manifest.target,
            .producer_name = producer_name,
            .producer_model = producer_model,
            .producer_version = producer_version,
            .producer_skill_version = producer_skill_version,
            .created_at = created_at,
            .finding_count = manifest.finding_count,
            .manifest_sha256 = artifacts.manifest_digest,
            .findings_sha256 = artifacts.findings_digest,
        },
        .artifacts = artifacts,
        .lifecycle = switch (exact.artifacts.state) {
            .new => .published,
            .draft => .draft,
            .completed => .result,
        },
    } };
}

/// Read one exact human result without returning Store paths or authority.
/// Pending is valid only after the same full Run and target admission.
pub fn readExactResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!ExactResultRead {
    var admitted = try admitExactRun(
        allocator,
        io,
        environment_map,
        repository_path,
        review_id,
        expected,
    );
    defer admitted.deinit(allocator);
    const exact = switch (admitted) {
        .failure => |failure| return .{ .failure = failure },
        .exact => |*value| value,
    };
    const manifest = &exact.artifacts.manifest.value;
    const identity: ResultIdentity = .{
        .review_repository_id = manifest.review_repository_id,
        .review_id = review_id,
        .target = manifest.target,
        .finding_count = manifest.finding_count,
        .findings_sha256 = exact.artifact_snapshot.findings_digest,
    };
    const result_bytes = exact.artifacts.result_bytes orelse return .{ .pending = identity };
    if (result_bytes.len == 0 or result_bytes.len > committed_review.limits.max_artifact_bytes) {
        return .{ .failure = .artifact_invalid };
    }
    const result_sha256 = exact.artifact_snapshot.result_digest orelse
        return .{ .failure = .artifact_invalid };
    exact.artifacts.result_bytes = null;
    return .{ .completed = .{
        .identity = identity,
        .result_sha256 = result_sha256,
        .result_bytes = result_bytes,
    } };
}

pub const PublicationFailure = enum {
    invalid_artifact,
    target_label_invalid,
    local_time_unavailable,
    run_name_collision,
    target_unavailable,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    duplicate_review_id,
    store_invalid,
    repository_invalid,
    main_worktree_unavailable,
    repository_name_invalid,
    repository_namespace_collision,
    git_failed,
    io_failed,
    binding_mismatch,
    concurrent_conflict,
    identity_missing,
    identity_invalid,
    identity_unavailable,
    identity_conflict,
    identity_duplicate,
    binding_move_required,
};
pub const PrepareSuccess = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    repository_display_name: store_name.RepositoryDisplayName,
    repository_directory_name: store_name.RepositoryDirectoryName,
};
pub const PrepareResult = union(enum) { success: PrepareSuccess, failure: PublicationFailure };
pub const PublishRequest = struct { repository_path: []const u8, review_repository_id: committed_review.ReviewRepositoryId, review_id: committed_review.ReviewId, manifest_bytes: []const u8, findings_bytes: []const u8 };
pub const PublishResult = union(enum) { success, failure: PublicationFailure };
pub const PersistenceFailure = mutation_store.Failure;
pub const ReviewRunBinding = mutation_store.RunBinding;
pub const DraftSaveRequest = mutation_store.DraftRequest;
pub const DraftSaveResult = mutation_store.DraftResult;
pub const ReviewResultCreateRequest = mutation_store.ResultRequest;
pub const ReviewResultCreateResult = mutation_store.ResultResult;
pub const DeleteRequest = core.DeleteRequest;
pub const DeleteResult = core.DeleteResult;
pub const MaintenanceFailure = core.MaintenanceFailure;
pub const CleanupResult = core.CleanupResult;

/// Owned Store-only facts used by maintenance commands. These deliberately
/// omit Git availability and retain no Store capability.
pub const MaintenanceRow = struct {
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    status: RunSummaryStatus,
    created_at: [20]u8,
    created_at_unix: i64,
    producer_name: []u8,
    producer_model: ?[]u8,
    finding_count: u32,
    artifacts: ArtifactSnapshot,
    logical_bytes: u64,

    pub fn deinit(self: *MaintenanceRow, allocator: std.mem.Allocator) void {
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }
};

pub const MaintenanceCatalog = struct {
    store: StoreSnapshot,
    rows: []MaintenanceRow,
    diagnostics: []Diagnostic,
    skipped_count: usize,
    orphan_count: usize,

    pub fn deinit(self: *MaintenanceCatalog, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const MaintenanceScanResult = union(enum) {
    unbound,
    bound_empty: StoreSnapshot,
    catalog: MaintenanceCatalog,
    failure: MaintenanceFailure,

    pub fn deinit(self: *MaintenanceScanResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .catalog => |*value| value.deinit(allocator),
            .unbound, .bound_empty, .failure => {},
        }
        self.* = .unbound;
    }
};

/// Scan the current repository namespace without requiring retained Git
/// objects. Mutation still goes through deleteFromPath and its fresh checks.
pub fn scanMaintenanceFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*std.process.Environ.Map,
    repository_path: []const u8,
) std.mem.Allocator.Error!MaintenanceScanResult {
    var repository = switch (try openRepository(allocator, io, environment, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = maintenancePublicationFailure(failure) },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment);
    defer resolved.deinit(allocator);
    const configured = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = maintenanceConfigFailure(failure) },
    };
    return scanMaintenanceLocated(
        allocator,
        io,
        configured,
        .{ .capability = &repository.root, .environment = &repository.environment },
        &repository.located,
    );
}

fn scanMaintenanceLocated(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
) std.mem.Allocator.Error!MaintenanceScanResult {
    return scanMaintenanceLocatedWithHook(allocator, io, configured, repository, located, null);
}

fn scanMaintenanceLocatedWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!MaintenanceScanResult {
    const instance_id = located.instanceId() orelse
        return .{ .failure = .binding_changed };
    switch (try core.probeBinding(allocator, io, configured.context(), located)) {
        .bound => {},
        .unbound => return .unbound,
        .failure => return .{ .failure = .binding_changed },
    }
    var scanned = try catalog_store.scan(allocator, io, configured.context(), instance_id);
    defer scanned.deinit(allocator);
    const source = switch (scanned) {
        .unbound => return .unbound,
        .bound_empty => |value| {
            if (try maintenanceFinalScanFailure(allocator, io, configured, repository, located, &scanned, hook)) |failure|
                return .{ .failure = failure };
            return .{ .bound_empty = value.snapshot };
        },
        .failure => |failure| return .{ .failure = maintenanceScanFailure(failure) },
        .catalog => |*value| value,
    };

    var rows: std.ArrayList(MaintenanceRow) = .empty;
    defer deinitMaintenanceRows(allocator, &rows);
    for (source.rows) |*row| {
        const owned = try maintenanceRowFromCatalog(allocator, row);
        rows.append(allocator, owned) catch |err| {
            var value = owned;
            value.deinit(allocator);
            return err;
        };
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &diagnostics);
    for (source.diagnostics) |diagnostic|
        try appendDiagnostic(allocator, &diagnostics, diagnostic.kind, diagnostic.text);

    if (try maintenanceFinalScanFailure(allocator, io, configured, repository, located, &scanned, hook)) |failure|
        return .{ .failure = failure };

    const owned_rows = try rows.toOwnedSlice(allocator);
    errdefer {
        for (owned_rows) |*row| row.deinit(allocator);
        allocator.free(owned_rows);
    }
    const owned_diagnostics = try diagnostics.toOwnedSlice(allocator);
    errdefer {
        for (owned_diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(owned_diagnostics);
    }
    return .{ .catalog = .{
        .store = source.snapshot,
        .rows = owned_rows,
        .diagnostics = owned_diagnostics,
        .skipped_count = source.skipped_count,
        .orphan_count = source.orphan_count,
    } };
}

/// Physical repository identity is checked without requiring retained Git objects.
pub fn deleteRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    request: DeleteRequest,
) std.mem.Allocator.Error!DeleteResult {
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .binding_changed },
    };
    const instance_id = located.instanceId() orelse return .{ .failure = .binding_changed };
    if (!instance_id.eql(request.store.repository_instance_id))
        return .{ .failure = .binding_changed };
    if (try maintenanceFinalBindingFailure(allocator, io, configured_store, repository, located, request.store)) |failure|
        return .{ .failure = failure };
    return core.deleteRun(allocator, io, configured_store.context(), .{
        .located = located,
        .context = repository.git(),
    }, request);
}

pub fn cleanupTrash(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    expected: StoreSnapshot,
) std.mem.Allocator.Error!CleanupResult {
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .binding_changed },
    };
    const instance_id = located.instanceId() orelse return .{ .failure = .binding_changed };
    if (!instance_id.eql(expected.repository_instance_id))
        return .{ .failure = .binding_changed };
    if (try maintenanceFinalBindingFailure(allocator, io, configured_store, repository, located, expected)) |failure|
        return .{ .failure = failure };
    return core.cleanupTrash(allocator, io, configured_store.context(), .{
        .located = located,
        .context = repository.git(),
    }, expected);
}

/// Owned display facts and freshness assertions, never a retained Store handle.
pub const DeletePreview = struct {
    store: StoreSnapshot,
    exact: ExactIdentity,
    status: RunSummaryStatus,

    pub fn deinit(self: *DeletePreview, allocator: std.mem.Allocator) void {
        self.exact.deinit(allocator);
        self.* = undefined;
    }
};

pub const DeletePreviewResult = union(enum) {
    preview: DeletePreview,
    failure: MaintenanceFailure,

    pub fn deinit(self: *DeletePreviewResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .preview => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

/// Confirmation reads the named Run only and does not require its Git objects.
pub fn previewDelete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
) std.mem.Allocator.Error!DeletePreviewResult {
    var repository = switch (try openRepository(allocator, io, environment, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = maintenancePublicationFailure(failure) },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment);
    defer resolved.deinit(allocator);
    const configured = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = maintenanceConfigFailure(failure) },
    };
    return previewDeleteLocated(
        allocator,
        io,
        configured,
        .{ .capability = &repository.root, .environment = &repository.environment },
        &repository.located,
        review_id,
    );
}

fn previewDeleteLocated(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    review_id: committed_review.ReviewId,
) std.mem.Allocator.Error!DeletePreviewResult {
    return previewDeleteLocatedWithHook(allocator, io, configured, repository, located, review_id, null);
}

fn previewDeleteLocatedWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    review_id: committed_review.ReviewId,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!DeletePreviewResult {
    const instance_id = located.instanceId() orelse return .{ .failure = .binding_changed };
    switch (try core.probeBinding(allocator, io, configured.context(), located)) {
        .bound => {},
        .unbound, .failure => return .{ .failure = .binding_changed },
    }
    var read = try catalog_store.readExact(allocator, io, configured.context(), instance_id, review_id, null, null);
    defer read.deinit(allocator);
    const exact = switch (read) {
        .exact => |*value| value,
        .absent => return .{ .failure = .not_found },
        .failure => |failure| return .{ .failure = maintenanceReadFailure(failure) },
    };
    if (hook) |value| value.fire();
    located.revalidate(allocator, io, repository.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .binding_changed };
    };
    if (try exactStoreFailure(
        allocator,
        io,
        configured.context(),
        located,
        instance_id,
        review_id,
        &exact.snapshot,
        exact.artifact_snapshot,
    )) |failure| return .{ .failure = maintenanceReadFailure(failure) };
    const identity = try identityFromExact(allocator, exact, review_id);
    return .{ .preview = .{
        .store = exact.snapshot,
        .exact = identity.exact,
        .status = if (exact.artifacts.result) |result| switch (result.value.result) {
            .approved => .approved,
            .needs_changes => .needs_changes,
            .canceled => .canceled,
        } else if (exact.artifacts.state == .draft) .draft else .new,
    } };
}

/// Freshly resolve the process input; deletion revalidates the preview assertions.
pub fn deleteFromPath(allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, repository_path: []const u8, request: DeleteRequest) std.mem.Allocator.Error!DeleteResult {
    var repository = switch (try openRepository(allocator, io, environment, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = maintenancePublicationFailure(failure) },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment);
    defer resolved.deinit(allocator);
    const configured = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = maintenanceConfigFailure(failure) },
    };
    return deleteRun(allocator, io, configured, .{ .capability = &repository.root, .environment = &repository.environment }, request);
}

pub fn cleanupFromPath(allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, repository_path: []const u8) std.mem.Allocator.Error!CleanupResult {
    var repository = switch (try openRepository(allocator, io, environment, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = maintenancePublicationFailure(failure) },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment);
    defer resolved.deinit(allocator);
    const configured = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = maintenanceConfigFailure(failure) },
    };
    const instance_id = repository.located.instanceId() orelse return .{ .failure = .binding_changed };
    var scanned = try catalog_store.scan(allocator, io, configured.context(), instance_id);
    defer scanned.deinit(allocator);
    const snapshot = switch (scanned) {
        .unbound => return .{ .failure = .not_found },
        .bound_empty => |value| value.snapshot,
        .catalog => |value| value.snapshot,
        .failure => |failure| return .{ .failure = switch (failure) {
            .permission_denied => .permission_denied,
            .io_failed, .registry_unavailable, .enumeration_failed => .io_failed,
            .store_unavailable => .store_unavailable,
            .unsupported_platform, .unsupported_filesystem => .unsupported,
            .registry_invalid => .binding_changed,
            .store_invalid, .namespace_invalid, .scan_limit_exceeded => .run_invalid,
        } },
    };
    return cleanupTrash(allocator, io, configured, .{ .capability = &repository.root, .environment = &repository.environment }, snapshot);
}

fn maintenanceReadFailure(failure: catalog_store.ReadFailure) MaintenanceFailure {
    return switch (failure) {
        .permission_denied => .permission_denied,
        .io_failed, .registry_unavailable => .io_failed,
        .store_unavailable => .store_unavailable,
        .unsupported_platform, .unsupported_filesystem => .unsupported,
        .root_changed, .binding_changed, .registry_invalid => .binding_changed,
        .artifact_changed, .concurrent_conflict => .conflict,
        .store_invalid, .namespace_invalid, .artifact_invalid => .run_invalid,
    };
}

fn maintenanceScanFailure(failure: catalog_store.ScanFailure) MaintenanceFailure {
    return switch (failure) {
        .permission_denied => .permission_denied,
        .io_failed, .registry_unavailable, .enumeration_failed => .io_failed,
        .store_unavailable => .store_unavailable,
        .unsupported_platform, .unsupported_filesystem => .unsupported,
        .registry_invalid => .binding_changed,
        .store_invalid, .namespace_invalid, .scan_limit_exceeded => .run_invalid,
    };
}

fn maintenanceRowFromCatalog(
    allocator: std.mem.Allocator,
    row: *const catalog_store.CatalogRow,
) std.mem.Allocator.Error!MaintenanceRow {
    var owned: MaintenanceRow = .{
        .review_id = row.review_id,
        .target = row.target,
        .status = row.status,
        .created_at = row.created_at,
        .created_at_unix = row.created_at_unix,
        .producer_name = try allocator.dupe(u8, row.producer_name),
        .producer_model = null,
        .finding_count = row.finding_count,
        .artifacts = row.artifact_snapshot,
        .logical_bytes = row.logical_bytes,
    };
    errdefer owned.deinit(allocator);
    if (row.producer_model) |value| owned.producer_model = try allocator.dupe(u8, value);
    return owned;
}

fn maintenanceConfigFailure(failure: config.ConfigLoadFailure) MaintenanceFailure {
    return switch (failure) {
        .read_permission_denied => .permission_denied,
        .read_failed => .io_failed,
        else => .run_invalid,
    };
}

fn maintenancePublicationFailure(failure: PublicationFailure) MaintenanceFailure {
    return switch (failure) {
        .store_unavailable => .store_unavailable,
        .unsupported_platform, .unsupported_filesystem => .unsupported,
        .repository_invalid, .main_worktree_unavailable, .repository_name_invalid, .binding_mismatch => .binding_changed,
        .store_invalid, .invalid_artifact, .target_label_invalid => .run_invalid,
        .duplicate_review_id, .repository_namespace_collision, .run_name_collision, .concurrent_conflict => .conflict,
        .target_unavailable, .local_time_unavailable, .git_failed, .io_failed => .io_failed,
        .identity_missing,
        .identity_invalid,
        .identity_unavailable,
        .identity_conflict,
        .identity_duplicate,
        .binding_move_required,
        => .binding_changed,
    };
}

fn maintenanceFinalBindingFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *const repository_locator.LocatedRepository,
    expected: StoreSnapshot,
) std.mem.Allocator.Error!?MaintenanceFailure {
    located.revalidate(allocator, io, repository.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .binding_changed;
    };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound, .failure => return .binding_changed,
    }
    return if (try catalog_store.validateSnapshot(allocator, io, configured_store.context(), expected)) |failure|
        maintenanceReadFailure(failure)
    else
        null;
}

fn maintenanceFinalScanFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *const repository_locator.LocatedRepository,
    expected: *const catalog_store.ScanResult,
    hook: ?BoundaryHook,
) std.mem.Allocator.Error!?MaintenanceFailure {
    if (hook) |value| value.fire();
    located.revalidate(allocator, io, repository.git()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .binding_changed;
    };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound, .failure => return .binding_changed,
    }
    const instance_id = located.instanceId() orelse return .binding_changed;
    var current = try catalog_store.scan(allocator, io, configured_store.context(), instance_id);
    defer current.deinit(allocator);
    return switch (current) {
        .failure => |failure| maintenanceScanFailure(failure),
        .unbound => .binding_changed,
        .bound_empty, .catalog => if (catalogScansEqual(expected, &current)) null else .binding_changed,
    };
}

const LocatePublicationResult = union(enum) {
    located: repository_locator.LocatedRepository,
    failure: PublicationFailure,

    fn deinit(self: *LocatePublicationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .located => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .repository_invalid };
    }
};

fn locateForPublication(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository: RepositoryContext,
) std.mem.Allocator.Error!LocatePublicationResult {
    return switch (try repository_locator.locate(allocator, io, repository.git())) {
        .located => |located| .{ .located = located },
        .failure => |failure| .{ .failure = switch (failure) {
            .unsupported_platform => .unsupported_platform,
            .git_command_failed => .git_failed,
            else => .repository_invalid,
        } },
    };
}

/// Prepare a binding from already-retained physical repository authority.
/// `repository_path` is diagnostic registry metadata only.
pub fn prepareWithRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    repository_path: []const u8,
) std.mem.Allocator.Error!PrepareResult {
    _ = repository_path;
    var located_result = try locateForPublication(allocator, io, repository);
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    return prepareLocated(allocator, io, configured_store, repository.git(), located);
}

fn prepareLocated(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: git_command.DirectoryContext,
    located: *repository_locator.LocatedRepository,
) std.mem.Allocator.Error!PrepareResult {
    const probe = try core.probeBinding(allocator, io, configured_store.context(), located);
    var main_worktree: repository_locator.MainWorktreeResult = .unavailable;
    defer main_worktree.deinit(allocator);
    const repository_name: ?[]const u8 = switch (probe) {
        .bound => null,
        .unbound => blk: {
            main_worktree = try repository_locator.mainWorktreeBasename(allocator, io, repository);
            break :blk switch (main_worktree) {
                .basename => |value| value,
                .unavailable => return .{ .failure = .main_worktree_unavailable },
            };
        },
        .failure => |failure| if (failure == .binding_move_required)
            null
        else
            return .{ .failure = mapPrepareCoreFailure(failure) },
    };
    return switch (try core.prepareBinding(allocator, io, configured_store.context(), .{
        .repository = located,
        .repository_context = repository,
        .repository_name = repository_name,
    })) {
        .success => |value| .{ .success = .{
            .review_repository_id = value.review_repository_id,
            .review_id = value.review_id,
            .repository_display_name = value.repository_display_name,
            .repository_directory_name = value.repository_directory_name,
        } },
        .failure => |failure| .{ .failure = mapPrepareCoreFailure(failure) },
    };
}

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
) std.mem.Allocator.Error!PrepareResult {
    var repository = switch (try openRepository(allocator, io, environment_map, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const configured_store = switch (resolved) {
        .store => |*value| value,
        .failure => return .{ .failure = .store_invalid },
    };
    return prepareLocated(allocator, io, configured_store, repository.git(), &repository.located);
}

/// Publish through the existing Store core using retained physical authority.
pub fn publishWithRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
    var located_result = try locateForPublication(allocator, io, repository);
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    return publishLocated(allocator, io, configured_store, repository, located, request);
}

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
    var repository = switch (try openRepository(allocator, io, environment_map, request.repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer repository.deinit();
    var resolved = try resolveConfiguredStore(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const configured_store = switch (resolved) {
        .store => |*value| value,
        .failure => return .{ .failure = .store_invalid },
    };
    return publishLocated(allocator, io, configured_store, .{
        .capability = &repository.root,
        .environment = &repository.environment,
    }, &repository.located, request);
}

fn publishLocated(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
    const instance_id = located.instanceId() orelse
        return .{ .failure = markerPublicationFailure(located.marker) };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound => return .{ .failure = .binding_mismatch },
        .failure => |failure| return .{ .failure = mapPrepareCoreFailure(failure) },
    }
    var manifest = committed_review.ReviewRunManifest.parseStrict(allocator, request.manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .invalid_artifact },
    };
    defer manifest.deinit();
    var findings = committed_review.FindingSet.parseStrict(allocator, request.findings_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .invalid_artifact },
    };
    defer findings.deinit();
    if (!manifest.value.review_id.eql(request.review_id) or
        !manifest.value.review_repository_id.eql(request.review_repository_id) or
        !findings.value.review_id.eql(request.review_id))
    {
        return .{ .failure = .invalid_artifact };
    }
    manifest.value.validateFindingSet(request.findings_bytes, &findings.value) catch
        return .{ .failure = .invalid_artifact };

    const availability = try git_review.checkTargetAvailability(allocator, io, repository.git(), manifest.value.target);
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => |failure| return .{ .failure = switch (failure) {
            .invalid_repository => .repository_invalid,
            .invalid_target => .invalid_artifact,
            else => .git_failed,
        } },
    }

    return switch (try core.publish(allocator, io, configured_store.context(), .{
        .located = located,
        .context = repository.git(),
    }, .{
        .repository_instance_id = instance_id,
        .review_repository_id = request.review_repository_id,
        .review_id = request.review_id,
        .manifest_bytes = request.manifest_bytes,
        .findings_bytes = request.findings_bytes,
    })) {
        .success => .success,
        .failure => |failure| .{ .failure = mapPublishCoreFailure(failure) },
    };
}

pub fn saveDraft(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    request: DraftSaveRequest,
) std.mem.Allocator.Error!DraftSaveResult {
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .binding_changed },
    };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound, .failure => return .{ .failure = .binding_changed },
    }
    return core.saveDraft(allocator, io, configured_store.context(), .{
        .located = located,
        .context = repository.git(),
    }, request);
}

pub fn createResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_store: *const ConfiguredStore,
    repository: RepositoryContext,
    request: ReviewResultCreateRequest,
) std.mem.Allocator.Error!ReviewResultCreateResult {
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return .{ .failure = .binding_changed },
    };
    switch (try core.probeBinding(allocator, io, configured_store.context(), located)) {
        .bound => {},
        .unbound, .failure => return .{ .failure = .binding_changed },
    }
    return core.createResult(allocator, io, configured_store.context(), .{
        .located = located,
        .context = repository.git(),
    }, request);
}

const OwnedRepository = struct {
    allocator: std.mem.Allocator,
    root: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,
    located: repository_locator.LocatedRepository,

    fn deinit(self: *OwnedRepository) void {
        self.located.deinit(self.allocator);
        self.environment.deinit();
        self.root.deinit();
        self.* = undefined;
    }

    fn git(self: *const OwnedRepository) git_command.DirectoryContext {
        return .{ .cwd = self.root.dir(), .environment = &self.environment };
    }
};

const RepositoryOpenResult = union(enum) { context: OwnedRepository, failure: PublicationFailure };

fn openRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
) std.mem.Allocator.Error!RepositoryOpenResult {
    var root = root_capability.RootCapability.openCanonical(repository_path) catch |err| {
        return .{ .failure = if (err == error.UnsupportedPlatform) .unsupported_platform else .repository_invalid };
    };
    errdefer root.deinit();
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .repository_invalid },
    };
    errdefer environment.deinit();
    const located = try repository_locator.locate(allocator, io, .{
        .cwd = root.dir(),
        .environment = &environment,
    });
    return switch (located) {
        .located => |value| .{ .context = .{
            .allocator = allocator,
            .root = root,
            .environment = environment,
            .located = value,
        } },
        .failure => |failure| blk: {
            environment.deinit();
            root.deinit();
            break :blk .{ .failure = switch (failure) {
                .git_command_failed => .git_failed,
                .unsupported_platform => .unsupported_platform,
                else => .repository_invalid,
            } };
        },
    };
}

const ResolvedConfiguredStore = union(enum) {
    store: ConfiguredStore,
    failure: config.ConfigLoadFailure,

    fn deinit(self: *ResolvedConfiguredStore, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .store => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .read_failed };
    }
};

fn resolveConfiguredStore(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
) std.mem.Allocator.Error!ResolvedConfiguredStore {
    var paths = try config.resolvePaths(allocator, environment_map);
    defer paths.deinit(allocator);
    var loaded = config.loadConfig(allocator, io, paths.config);
    defer loaded.deinit();
    const configured = switch (loaded) {
        .success => |*owned| owned.value.ai_review.store_root,
        .failure => |failure| return .{ .failure = failure },
    };
    const value = ConfiguredStore.init(allocator, configured, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .invalid_ai_review_store_root },
    };
    return .{ .store = value };
}

fn expectedIdentityMatches(
    expected: ExpectedPublicationIdentity,
    manifest: *const committed_review.ReviewRunManifest,
    artifacts: ArtifactSnapshot,
) bool {
    return expected.review_repository_id.eql(manifest.review_repository_id) and
        expected.target.eql(&manifest.target) and
        expected.producer.eql(manifest.producer) and
        std.mem.eql(u8, expected.created_at, manifest.created_at) and
        expected.finding_count == manifest.finding_count and
        expected.manifest_sha256.eql(artifacts.manifest_digest) and
        expected.findings_sha256.eql(artifacts.findings_digest);
}

fn mapCatalogScanFailure(failure: catalog_store.ScanFailure) ScanFailure {
    return switch (failure) {
        .permission_denied => .store_unavailable,
        .io_failed => .store_invalid,
        .store_invalid => .store_invalid,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .registry_invalid => .registry_invalid,
        .registry_unavailable => .registry_unavailable,
        .namespace_invalid => .namespace_invalid,
        .enumeration_failed => .enumeration_failed,
        .scan_limit_exceeded => .scan_limit_exceeded,
    };
}

fn markerPublicationFailure(state: repository_locator.MarkerState) PublicationFailure {
    return switch (state) {
        .present => .identity_conflict,
        .missing => .identity_missing,
        .invalid => .identity_invalid,
        .unavailable => .identity_unavailable,
    };
}

fn markerScanFailure(state: repository_locator.MarkerState) ScanFailure {
    return switch (state) {
        .present => .identity_conflict,
        .missing => .identity_missing,
        .invalid => .identity_invalid,
        .unavailable => .identity_unavailable,
    };
}

fn markerErrorScanFailure(err: anyerror) ScanFailure {
    return switch (err) {
        error.identity_missing => .identity_missing,
        error.identity_invalid => .identity_invalid,
        error.identity_unavailable => .identity_unavailable,
        error.identity_conflict => .identity_conflict,
        else => .identity_unavailable,
    };
}

fn mapProbeScanFailure(failure: core.PrepareBindingFailure) ScanFailure {
    return switch (failure) {
        .identity_missing => .identity_missing,
        .identity_invalid => .identity_invalid,
        .identity_unavailable => .identity_unavailable,
        .identity_conflict => .identity_conflict,
        .identity_duplicate => .identity_duplicate,
        .binding_move_required => .binding_move_required,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .registry_invalid,
        .repository_invalid, .repository_name_invalid => .repository_invalid,
        .repository_namespace_collision, .concurrent_conflict => .store_invalid,
        .io_failed => .store_unavailable,
    };
}

fn markerReadFailure(state: repository_locator.MarkerState) ReadFailure {
    return switch (state) {
        .present => .identity_conflict,
        .missing => .identity_missing,
        .invalid => .identity_invalid,
        .unavailable => .identity_unavailable,
    };
}

fn markerErrorReadFailure(err: anyerror) ReadFailure {
    return switch (err) {
        error.identity_missing => .identity_missing,
        error.identity_invalid => .identity_invalid,
        error.identity_unavailable => .identity_unavailable,
        error.identity_conflict => .identity_conflict,
        else => .identity_unavailable,
    };
}

fn probeReadFailure(failure: core.PrepareBindingFailure) ReadFailure {
    return switch (failure) {
        .identity_missing => .identity_missing,
        .identity_invalid => .identity_invalid,
        .identity_unavailable => .identity_unavailable,
        .identity_conflict => .identity_conflict,
        .identity_duplicate => .identity_duplicate,
        .binding_move_required => .binding_move_required,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .store_invalid,
        .repository_invalid, .repository_name_invalid => .repository_invalid,
        .repository_namespace_collision, .concurrent_conflict => .concurrent_conflict,
        .io_failed => .io_failed,
    };
}

fn summaryFromCatalogRow(allocator: std.mem.Allocator, row: *const catalog_store.CatalogRow) std.mem.Allocator.Error!RunSummary {
    var summary: RunSummary = .{
        .review_id = row.review_id,
        .target = row.target,
        .status = row.status,
        .created_at = row.created_at,
        .created_at_unix = row.created_at_unix,
        .producer_name = try allocator.dupe(u8, row.producer_name),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = row.finding_count,
        .availability = .available,
        .artifact_snapshot = row.artifact_snapshot,
    };
    errdefer summary.deinit(allocator);
    if (row.producer_model) |value| summary.producer_model = try allocator.dupe(u8, value);
    if (row.base_label) |value| summary.base_label = try allocator.dupe(u8, value);
    if (row.head_label) |value| summary.head_label = try allocator.dupe(u8, value);
    return summary;
}

fn summaryLessThan(_: void, left: RunSummary, right: RunSummary) bool {
    if (left.created_at_unix != right.created_at_unix) return left.created_at_unix > right.created_at_unix;
    const left_text = left.review_id.canonical();
    const right_text = right.review_id.canonical();
    return std.mem.lessThan(u8, &left_text, &right_text);
}

fn appendDiagnostic(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic), kind: DiagnosticKind, raw_name: []const u8) std.mem.Allocator.Error!void {
    if (diagnostics.items.len == max_diagnostics) return;
    const sanitized = try sanitizeDiagnostic(allocator, raw_name);
    diagnostics.append(allocator, .{ .kind = kind, .text = sanitized }) catch |err| {
        allocator.free(sanitized);
        return err;
    };
}

fn sanitizeDiagnostic(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const length = @min(raw.len, max_diagnostic_bytes);
    const value = try allocator.alloc(u8, length);
    for (raw[0..length], 0..) |byte, index| value[index] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    return value;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(RunSummary)) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitMaintenanceRows(allocator: std.mem.Allocator, rows: *std.ArrayList(MaintenanceRow)) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitDiagnostics(allocator: std.mem.Allocator, values: *std.ArrayList(Diagnostic)) void {
    for (values.items) |*value| value.deinit(allocator);
    values.deinit(allocator);
}

fn mapExactSelectionFailure(failure: catalog_store.ReadFailure) SelectionFailure {
    return switch (failure) {
        .permission_denied => .root_drift,
        .io_failed => .run_invalid,
        .root_changed => .root_drift,
        .binding_changed => .binding_drift,
        .artifact_changed => .artifact_drift,
        .registry_invalid, .registry_unavailable => .binding_drift,
        .artifact_invalid, .namespace_invalid, .concurrent_conflict => .run_invalid,
        .store_unavailable, .unsupported_platform, .unsupported_filesystem, .store_invalid => .root_drift,
    };
}

fn mapExactIdentityFailure(failure: catalog_store.ReadFailure) ReadFailure {
    return switch (failure) {
        .permission_denied => .store_unavailable,
        .io_failed => .io_failed,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .store_invalid,
        .registry_invalid, .namespace_invalid => .binding_invalid,
        .registry_unavailable => .io_failed,
        .artifact_invalid => .artifact_invalid,
        .root_changed => .root_changed,
        .binding_changed => .binding_changed,
        .artifact_changed => .artifact_changed,
        .concurrent_conflict => .concurrent_conflict,
    };
}

fn mapPublicationToReadFailure(failure: PublicationFailure) ReadFailure {
    return switch (failure) {
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .store_invalid,
        .repository_invalid => .repository_invalid,
        .main_worktree_unavailable, .repository_name_invalid => .repository_invalid,
        .repository_namespace_collision => .concurrent_conflict,
        .git_failed => .git_failed,
        .io_failed => .io_failed,
        .binding_mismatch => .binding_invalid,
        .concurrent_conflict => .concurrent_conflict,
        .invalid_artifact => .artifact_invalid,
        .target_label_invalid => .artifact_invalid,
        .local_time_unavailable => .io_failed,
        .run_name_collision => .concurrent_conflict,
        .target_unavailable => .target_unavailable,
        .duplicate_review_id => .io_failed,
        .identity_missing => .identity_missing,
        .identity_invalid => .identity_invalid,
        .identity_unavailable => .identity_unavailable,
        .identity_conflict => .identity_conflict,
        .identity_duplicate => .identity_duplicate,
        .binding_move_required => .binding_move_required,
    };
}

fn mapPrepareCoreFailure(failure: core.PrepareBindingFailure) PublicationFailure {
    return switch (failure) {
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .store_invalid,
        .repository_invalid => .repository_invalid,
        .repository_name_invalid => .repository_name_invalid,
        .repository_namespace_collision => .repository_namespace_collision,
        .io_failed => .io_failed,
        .concurrent_conflict => .concurrent_conflict,
        .identity_missing => .identity_missing,
        .identity_invalid => .identity_invalid,
        .identity_unavailable => .identity_unavailable,
        .identity_conflict => .identity_conflict,
        .identity_duplicate => .identity_duplicate,
        .binding_move_required => .binding_move_required,
    };
}

fn mapPublishCoreFailure(failure: core.PublishFailure) PublicationFailure {
    return switch (failure) {
        .invalid_artifact => .invalid_artifact,
        .target_label_invalid => .target_label_invalid,
        .local_time_unavailable => .local_time_unavailable,
        .run_name_collision => .run_name_collision,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .duplicate_review_id => .duplicate_review_id,
        .store_invalid => .store_invalid,
        .io_failed => .io_failed,
        .binding_mismatch => .binding_mismatch,
        .concurrent_conflict => .concurrent_conflict,
    };
}

test "AI Review Store application configured context clones without opening authority" {
    const allocator = std.testing.allocator;
    var store = try ConfiguredStore.initConfigured(allocator, "/definitely/missing/gitframe-review-store");
    defer store.deinit(allocator);
    var duplicate = try store.clone(allocator);
    defer duplicate.deinit(allocator);
    try std.testing.expect(store.isConfigured());
    try std.testing.expect(store.identity().eql(duplicate.identity()));
    try std.testing.expect(duplicate.context().openExisting() == .missing);

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", "/definitely/missing");
    var resolved = try ConfiguredStore.init(allocator, null, &environment);
    defer resolved.deinit(allocator);
    var explicit = try ConfiguredStore.initConfigured(allocator, "/definitely/missing/gitframe/ai-reviews");
    defer explicit.deinit(allocator);
    try std.testing.expect(resolved.identity().eql(explicit.identity()));
}

test "AI Review Store ownership proof has one application composition owner and no read fallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(allocator);
    defer walker.deinit();
    var composition_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        const source = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        const production = applicationProductionPrefix(source);
        const imports_store_core = std.mem.indexOf(u8, production, "review_store/core.zig\")") != null or
            std.mem.indexOf(u8, production, "review_store/catalog.zig\")") != null;
        const imports_repository_git = std.mem.indexOf(u8, production, "git/command.zig\")") != null or
            std.mem.indexOf(u8, production, "git/committed_review.zig\")") != null or
            std.mem.indexOf(u8, production, "git/repository_locator.zig\")") != null;
        if (imports_store_core and imports_repository_git) {
            composition_count += 1;
            try std.testing.expectEqualStrings("ai_review/store_service.zig", entry.path);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), composition_count);

    const configured_fields = @typeInfo(ConfiguredStore).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), configured_fields.len);
    try std.testing.expectEqualStrings("state", configured_fields[0].name);
    try std.testing.expect(@typeInfo(configured_fields[0].type) == .pointer);
    const configured_state = @typeInfo(configured_fields[0].type).pointer;
    try std.testing.expect(@typeInfo(configured_state.child) == .@"opaque");
    try std.testing.expect(configured_fields[0].type != *core.Context);

    const selected_fields = @typeInfo(SelectedRunRead).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), selected_fields.len);
    inline for (selected_fields, .{ "snapshot", "artifacts", "projection", "finding_projection" }) |field, expected_name| {
        try std.testing.expectEqualStrings(expected_name, field.name);
        try std.testing.expect(field.type != @FieldType(core.OpenedRoot, "root"));
        try std.testing.expect(field.type != root_capability.RootCapability);
        try std.testing.expect(field.type != git_command.LocalGitEnvironment);
    }

    const own_source = try std.Io.Dir.cwd().readFileAlloc(io, "src/ai_review/store_service.zig", allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(own_source);
    const read_start = std.mem.indexOf(u8, own_source, "fn admitExactRun(") orelse return error.MissingExactReader;
    const read_end = std.mem.indexOfPos(u8, own_source, read_start, "pub const PublicationFailure") orelse return error.MissingExactReaderEnd;
    const exact_reader = own_source[read_start..read_end];
    try std.testing.expect(std.mem.indexOf(u8, exact_reader, "catalog_store.readExact(") != null);
    inline for (.{ "catalog_store.scan(", "summaryLessThan", "std.mem.sort", "newest", "mtime" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, exact_reader, forbidden) == null);
    }

    inline for (.{
        "src/app.zig",
        "src/app/load.zig",
        "src/app/message.zig",
        "src/config.zig",
        "src/main.zig",
        "src/root.zig",
        "src/ai_review/store_read_command.zig",
        "src/ai_review/result_read_command.zig",
        "src/review_store/prepare_command.zig",
        "src/review_store/publish_command.zig",
    }) |path| {
        const consumer = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(consumer);
        const production = applicationProductionPrefix(consumer);
        try std.testing.expect(std.mem.indexOf(u8, production, "review_store.history") == null);
        inline for (.{
            "review_store/path.zig",
            "review_store/capability.zig",
            "review_store/registry.zig",
            "review_store/run.zig",
            "review_store/history.zig",
            "review_store/publication.zig",
            "review_store/mutation.zig",
            "review_store/core.zig",
            "review_store/catalog.zig",
        }) |raw_import| {
            try std.testing.expect(std.mem.indexOf(u8, production, raw_import) == null);
        }
    }

    const facade_source = try std.Io.Dir.cwd().readFileAlloc(io, "src/review_store.zig", allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(facade_source);
    const facade = applicationProductionPrefix(facade_source);
    inline for (.{
        "pub const path",
        "pub const capability",
        "pub const registry",
        "pub const run",
        "StoreRootCapability",
        "DirectoryCapability",
        "ParsedRegistry",
        "ResolvedPath",
        "@import(\"review_store/path.zig\")",
        "@import(\"review_store/capability.zig\")",
        "@import(\"review_store/registry.zig\")",
        "@import(\"review_store/run.zig\")",
        "@import(\"review_store/publication.zig\")",
        "@import(\"review_store/mutation.zig\")",
    }) |raw_surface| {
        try std.testing.expect(std.mem.indexOf(u8, facade, raw_surface) == null);
    }
    inline for (.{
        "ConfiguredStore",
        "ConfigurationIdentity",
        "readExactIdentity",
        "readExactResult",
        "prepare",
        "publish",
        "saveDraft",
        "createResult",
    }) |semantic_surface| {
        try std.testing.expect(std.mem.indexOf(u8, facade, semantic_surface) != null);
    }
}

fn applicationProductionPrefix(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        if (std.mem.startsWith(u8, line, "test ") or std.mem.eql(u8, line, "test")) return source[0..start];
        start = if (end == source.len) source.len else end + 1;
    }
    return source;
}

// Test-only low-level fixture authority. Production composition above reaches
// Store descriptors exclusively through core/catalog semantic results.
const capability = @import("../review_store/capability.zig");

fn scanCompatibility(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
) std.mem.Allocator.Error!ScanResult {
    var configured = ConfiguredStore.initConfigured(allocator, store_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .store_invalid },
    };
    defer configured.deinit(allocator);
    return scan(allocator, io, &configured, repository);
}

fn loadSelectionCompatibility(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: ArtifactSnapshot,
) std.mem.Allocator.Error!SelectionResult {
    var configured = ConfiguredStore.initConfigured(allocator, store_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .root_drift },
    };
    defer configured.deinit(allocator);
    return selectExact(allocator, io, &configured, repository, expected, review_id, expected_artifacts);
}

test "Finding disposition reload relaxes only mutable artifact identity" {
    const original: ArtifactSnapshot = .{
        .manifest_digest = committed_review.Sha256Digest.hash("manifest"),
        .findings_digest = committed_review.Sha256Digest.hash("findings"),
        .draft_state = .valid,
        .draft_digest = committed_review.Sha256Digest.hash("draft-1"),
        .result_digest = null,
    };
    var mutable_drift = original;
    mutable_drift.draft_state = .absent;
    mutable_drift.draft_digest = null;
    mutable_drift.result_digest = committed_review.Sha256Digest.hash("result");
    try std.testing.expect(immutableArtifactIdentityEql(mutable_drift, original));

    var manifest_drift = mutable_drift;
    manifest_drift.manifest_digest = committed_review.Sha256Digest.hash("changed manifest");
    try std.testing.expect(!immutableArtifactIdentityEql(manifest_drift, original));
    var findings_drift = mutable_drift;
    findings_drift.findings_digest = committed_review.Sha256Digest.hash("changed findings");
    try std.testing.expect(!immutableArtifactIdentityEql(findings_drift, original));
}

test "review history backend summary sorting ignores filesystem and completion time" {
    const older = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const first_tie = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    var rows = [_]RunSummary{
        undefined,
        undefined,
        undefined,
    };
    rows[0].review_id = older;
    rows[0].created_at_unix = 1;
    rows[1].review_id = older;
    rows[1].created_at_unix = 2;
    rows[2].review_id = first_tie;
    rows[2].created_at_unix = 2;
    std.mem.sort(RunSummary, &rows, {}, summaryLessThan);
    try std.testing.expect(rows[0].review_id.eql(first_tie));
    try std.testing.expect(rows[1].review_id.eql(older));
    try std.testing.expectEqual(@as(i64, 1), rows[2].created_at_unix);
}

test "review history backend diagnostics are bounded and terminal-control safe" {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(std.testing.allocator, &diagnostics);
    for (0..max_diagnostics + 4) |index| {
        const raw = if (index == 0) "bad\n\x1bname" else "bad";
        try appendDiagnostic(std.testing.allocator, &diagnostics, .invalid_run, raw);
    }
    try std.testing.expectEqual(max_diagnostics, diagnostics.items.len);
    try std.testing.expectEqualStrings("bad??name", diagnostics.items[0].text);
}

const TestRunMode = enum {
    new,
    draft,
    completed,
    completed_needs_changes,
    completed_canceled,
    completed_invalid_draft,
    completed_unsafe_draft,
    completed_oversized_draft,
    invalid_result,
    unknown_entry,
};

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    return error.GitCommandFailed;
}

fn runTestGitDiscard(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const stdout = try runTestGit(io, cwd, argv);
    std.testing.allocator.free(stdout);
}

fn singleOutputLine(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n' or
        std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') != null)
    {
        return error.InvalidGitOutput;
    }
    return bytes[0 .. bytes.len - 1];
}

fn writePrivate(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

const ReadStateContext = struct {
    repository: std.Io.Dir,
    repository_path: []const u8,
    store_path: []const u8,
};

const ReadOnlyState = struct {
    head: []u8,
    branch: []u8,
    index: []u8,
    local_config: []u8,
    worktree: []u8,
    store: []u8,

    fn deinit(self: *ReadOnlyState, allocator: std.mem.Allocator) void {
        allocator.free(self.store);
        allocator.free(self.worktree);
        allocator.free(self.local_config);
        allocator.free(self.index);
        allocator.free(self.branch);
        allocator.free(self.head);
        self.* = undefined;
    }
};

fn captureReadOnlyState(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ReadStateContext,
) !ReadOnlyState {
    const head = try runTestGit(io, context.repository, &.{ "git", "--no-optional-locks", "rev-parse", "--verify", "HEAD" });
    errdefer allocator.free(head);
    const branch = try runTestGit(io, context.repository, &.{ "git", "--no-optional-locks", "rev-parse", "--symbolic-full-name", "HEAD" });
    errdefer allocator.free(branch);
    const index_path_output = try runTestGit(io, context.repository, &.{ "git", "--no-optional-locks", "rev-parse", "--path-format=absolute", "--git-path", "index" });
    defer allocator.free(index_path_output);
    const index_path = try singleOutputLine(index_path_output);
    const index = try std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(64 * 1024 * 1024));
    errdefer allocator.free(index);
    const local_config = try runTestGit(io, context.repository, &.{ "git", "--no-optional-locks", "config", "--local", "--null", "--list" });
    errdefer allocator.free(local_config);
    const worktree = try directoryInventory(allocator, io, context.repository_path, true);
    errdefer allocator.free(worktree);
    const store = try directoryInventory(allocator, io, context.store_path, false);
    return .{
        .head = head,
        .branch = branch,
        .index = index,
        .local_config = local_config,
        .worktree = worktree,
        .store = store,
    };
}

fn expectReadOnlyStateEqual(before: ReadOnlyState, after: ReadOnlyState) !void {
    if (!std.mem.eql(u8, before.head, after.head)) return error.ReadMutatedHead;
    if (!std.mem.eql(u8, before.branch, after.branch)) return error.ReadMutatedBranch;
    if (!std.mem.eql(u8, before.index, after.index)) return error.ReadMutatedIndex;
    if (!std.mem.eql(u8, before.local_config, after.local_config)) return error.ReadMutatedRemote;
    if (!std.mem.eql(u8, before.worktree, after.worktree)) return error.ReadMutatedWorktree;
    if (!std.mem.eql(u8, before.store, after.store)) return error.ReadMutatedStore;
}

fn expectReadOnlyStateSensitivity(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ReadStateContext,
) !void {
    {
        var baseline = try captureReadOnlyState(allocator, io, context);
        defer baseline.deinit(allocator);
        const original_branch = try singleOutputLine(baseline.branch);
        try runTestGitDiscard(io, context.repository, &.{ "git", "branch", "read-state-proof", "HEAD" });
        try runTestGitDiscard(io, context.repository, &.{ "git", "symbolic-ref", "HEAD", "refs/heads/read-state-proof" });
        var changed = try captureReadOnlyState(allocator, io, context);
        defer changed.deinit(allocator);
        try std.testing.expectError(error.ReadMutatedBranch, expectReadOnlyStateEqual(baseline, changed));
        try runTestGitDiscard(io, context.repository, &.{ "git", "symbolic-ref", "HEAD", original_branch });
        try runTestGitDiscard(io, context.repository, &.{ "git", "branch", "--delete", "--force", "read-state-proof" });
        var restored = try captureReadOnlyState(allocator, io, context);
        defer restored.deinit(allocator);
        try expectReadOnlyStateEqual(baseline, restored);
    }

    {
        var baseline = try captureReadOnlyState(allocator, io, context);
        defer baseline.deinit(allocator);
        try runTestGitDiscard(io, context.repository, &.{ "git", "update-index", "--skip-worktree", "file.txt" });
        var changed = try captureReadOnlyState(allocator, io, context);
        defer changed.deinit(allocator);
        try std.testing.expectError(error.ReadMutatedIndex, expectReadOnlyStateEqual(baseline, changed));
        try runTestGitDiscard(io, context.repository, &.{ "git", "update-index", "--no-skip-worktree", "file.txt" });
    }

    {
        var baseline = try captureReadOnlyState(allocator, io, context);
        defer baseline.deinit(allocator);
        try runTestGitDiscard(io, context.repository, &.{ "git", "remote", "add", "read-state-proof", "https://example.invalid/repository" });
        var changed = try captureReadOnlyState(allocator, io, context);
        defer changed.deinit(allocator);
        try std.testing.expectError(error.ReadMutatedRemote, expectReadOnlyStateEqual(baseline, changed));
        try runTestGitDiscard(io, context.repository, &.{ "git", "remote", "remove", "read-state-proof" });
        var restored = try captureReadOnlyState(allocator, io, context);
        defer restored.deinit(allocator);
        try expectReadOnlyStateEqual(baseline, restored);
    }
}

fn inventoryLineLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn collectDirectoryInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    prefix: []const u8,
    skip_root_git: bool,
    lines: *std.ArrayList([]u8),
) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (skip_root_git and prefix.len == 0 and std.mem.eql(u8, entry.name, ".git")) continue;
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(relative);
        const stat = try directory.statFile(io, entry.name, .{ .follow_symlinks = false });
        const mode = stat.permissions.toMode() & 0o7777;
        switch (entry.kind) {
            .directory => {
                const line = try std.fmt.allocPrint(allocator, "{s}\tdirectory\t{o}\n", .{ relative, mode });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
                var child = try directory.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try collectDirectoryInventory(allocator, io, child, relative, false, lines);
            },
            .file => {
                const bytes = try directory.readFileAlloc(io, entry.name, allocator, .limited(64 * 1024 * 1024));
                defer allocator.free(bytes);
                const digest = committed_review.Sha256Digest.hash(bytes).canonical();
                const line = try std.fmt.allocPrint(allocator, "{s}\tfile\t{o}\t{d}\t{s}\n", .{ relative, mode, bytes.len, &digest });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
            .sym_link => {
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target_length = try directory.readLink(io, entry.name, &target_buffer);
                const target = target_buffer[0..target_length];
                const line = try std.fmt.allocPrint(allocator, "{s}\tsym_link\t{o}\t{d}:{s}\n", .{ relative, mode, target.len, target });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
            else => {
                const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\t{o}\n", .{ relative, @tagName(entry.kind), mode });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
        }
    }
}

fn directoryInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    skip_root_git: bool,
) ![]u8 {
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer directory.close(io);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    try collectDirectoryInventory(allocator, io, directory, "", skip_root_git, &lines);
    std.mem.sort([]u8, lines.items, {}, inventoryLineLessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (lines.items) |line| try result.appendSlice(allocator, line);
    return result.toOwnedSlice(allocator);
}

test "review store preparation distinguishes unavailable main worktree and invalid repository name" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store-bare", .fromMode(0o700));
    try tmp.dir.createDir(io, "store-invalid", .fromMode(0o700));
    allocator.free(try runTestGit(io, tmp.dir, &.{ "git", "init", "--bare", "Bare.git" }));
    try tmp.dir.createDir(io, "---", .default_dir);
    var invalid_repo = try tmp.dir.openDir(io, "---", .{});
    defer invalid_repo.close(io);
    allocator.free(try runTestGit(io, invalid_repo, &.{ "git", "init", "--initial-branch=main" }));

    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    inline for (.{
        .{ "Bare.git", "store-bare", PublicationFailure.main_worktree_unavailable },
        .{ "---", "store-invalid", PublicationFailure.repository_name_invalid },
    }) |case| {
        const repository_path = try tmp.dir.realPathFileAlloc(io, case[0], allocator);
        defer allocator.free(repository_path);
        const store_path_text = try tmp.dir.realPathFileAlloc(io, case[1], allocator);
        defer allocator.free(store_path_text);
        var root = try root_capability.RootCapability.openCanonical(repository_path);
        defer root.deinit();
        var configured = try ConfiguredStore.initConfigured(allocator, store_path_text);
        defer configured.deinit(allocator);
        const result = try prepareWithRepository(
            allocator,
            io,
            &configured,
            .{ .capability = &root, .environment = &environment },
            repository_path,
        );
        try std.testing.expectEqual(case[2], result.failure);
        if (case[2] == .main_worktree_unavailable) {
            var store = try tmp.dir.openDir(io, case[1], .{ .iterate = true });
            defer store.close(io);
            var iterator = store.iterate();
            try std.testing.expect(try iterator.next(io) == null);
        }
    }
}

test "review store preparation never reruns main-worktree discovery for an existing binding" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "Bound-Repo", .default_dir);
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    try tmp.dir.createDir(io, "bin", .default_dir);
    var repo = try tmp.dir.openDir(io, "Bound-Repo", .{});
    defer repo.close(io);
    allocator.free(try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" }));
    const repository_path = try tmp.dir.realPathFileAlloc(io, "Bound-Repo", allocator);
    defer allocator.free(repository_path);
    const common_path = try std.fs.path.join(allocator, &.{ repository_path, ".git" });
    defer allocator.free(common_path);
    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var root = try root_capability.RootCapability.openCanonical(repository_path);
    defer root.deinit();
    var configured = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer configured.deinit(allocator);
    var normal_environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer normal_environment.deinit();
    const first_result = try prepareWithRepository(
        allocator,
        io,
        &configured,
        .{ .capability = &root, .environment = &normal_environment },
        repository_path,
    );
    const first = switch (first_result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };

    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nif [ \"$1\" = \"--no-optional-locks\" ] && [ \"$2\" = \"rev-parse\" ]; then\n  printf '%s\\n' \"{s}\"\n  exit 0\nfi\nif [ \"$1\" = \"--no-optional-locks\" ] && [ \"$2\" = \"worktree\" ]; then\n  exit 71\nfi\nexit 70\n",
        .{common_path},
    );
    defer allocator.free(script);
    var bin = try tmp.dir.openDir(io, "bin", .{});
    defer bin.close(io);
    try bin.writeFile(io, .{
        .sub_path = "git",
        .data = script,
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const bin_path = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
    defer allocator.free(bin_path);
    var parent_environment = std.process.Environ.Map.init(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("PATH", bin_path);
    var worktree_failing_environment = try git_command.LocalGitEnvironment.initFromParent(allocator, &parent_environment);
    defer worktree_failing_environment.deinit();
    const second_result = try prepareWithRepository(
        allocator,
        io,
        &configured,
        .{ .capability = &root, .environment = &worktree_failing_environment },
        repository_path,
    );
    const second = switch (second_result) {
        .success => |value| value,
        .failure => return error.MainWorktreeDiscoveryWasRepeated,
    };
    try std.testing.expect(first.review_repository_id.eql(second.review_repository_id));
    try std.testing.expect(first.repository_display_name.eql(&second.repository_display_name));
    try std.testing.expect(first.repository_directory_name.eql(&second.repository_directory_name));

    root.deinit();
    try tmp.dir.rename("Bound-Repo", tmp.dir, "Renamed-Repo", io);
    const renamed_path = try tmp.dir.realPathFileAlloc(io, "Renamed-Repo", allocator);
    defer allocator.free(renamed_path);
    root = try root_capability.RootCapability.openCanonical(renamed_path);
    var before_transfer = try scan(
        allocator,
        io,
        &configured,
        .{ .capability = &root, .environment = &normal_environment },
    );
    defer before_transfer.deinit(allocator);
    try std.testing.expectEqual(ScanFailure.binding_move_required, before_transfer.failure);
    const transferred_result = try prepareWithRepository(
        allocator,
        io,
        &configured,
        .{ .capability = &root, .environment = &normal_environment },
        renamed_path,
    );
    const transferred = switch (transferred_result) {
        .success => |value| value,
        .failure => return error.ExpectedLeaseTransfer,
    };
    try std.testing.expect(first.review_repository_id.eql(transferred.review_repository_id));
    try std.testing.expect(first.repository_directory_name.eql(&transferred.repository_directory_name));
}

test "review store deletion service preserves Git and sibling Runs without target objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    for ([_][]const []const u8{
        &.{ "git", "init", "--initial-branch=main" },
        &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture" },
    }) |argv| allocator.free(try runTestGit(io, repo, argv));
    try repo.writeFile(io, .{ .sub_path = "local.txt", .data = "keep staged\n" });
    allocator.free(try runTestGit(io, repo, &.{ "git", "add", "local.txt" }));
    try repo.writeFile(io, .{ .sub_path = "local.txt", .data = "keep unstaged\n" });
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    var repo_capability = try root_capability.RootCapability.openCanonical(repo_path);
    defer repo_capability.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const repository: RepositoryContext = .{ .capability = &repo_capability, .environment = &environment };
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var configured = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer configured.deinit(allocator);
    const prepared = (try core.prepareBinding(allocator, io, configured.context(), .{
        .repository = located,
        .repository_context = repository.git(),
        .repository_name = "repo",
    })).success;
    const instance_id = located.instanceId().?;
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_text = prepared.review_repository_id.canonical();
    var locks = try store.openDir(io, ".locks", .{});
    defer locks.close(io);
    try locks.createDir(io, &repository_text, .fromMode(0o700));
    var namespace = try store.openDir(io, prepared.repository_directory_name.slice(), .{});
    defer namespace.close(io);
    // These object IDs have never existed in this Git repository.
    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const target: committed_review.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
    const sibling = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, prepared.review_id, target, "2026-08-20T08:00:00Z", .completed_invalid_draft);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, sibling, target, "2026-08-20T08:00:00Z", .draft);
    const other_repository_id = try committed_review.ReviewRepositoryId.parse("323e4567-e89b-42d3-a456-426614174000");
    const other_display = try store_name.RepositoryDisplayName.fromStored("other");
    const other_directory_name = store_name.RepositoryDirectoryName.format(&other_display, other_repository_id);
    try store.createDir(io, other_directory_name.slice(), .fromMode(0o700));
    var other_namespace = try store.openDir(io, other_directory_name.slice(), .{});
    defer other_namespace.close(io);
    try seedTestRun(allocator, io, other_namespace, other_repository_id, prepared.review_id, target, "2026-08-20T08:00:00Z", .completed);
    var scanned = try catalog_store.scan(allocator, io, configured.context(), instance_id);
    defer scanned.deinit(allocator);
    const catalog = &scanned.catalog;
    const artifacts: ArtifactSnapshot = found: {
        for (catalog.rows) |row| if (row.review_id.eql(prepared.review_id)) break :found row.artifact_snapshot;
        return error.MissingFixtureRun;
    };
    var preview_result = try previewDeleteLocated(allocator, io, &configured, repository, located, prepared.review_id);
    defer preview_result.deinit(allocator);
    const preview = &preview_result.preview;
    try std.testing.expect(preview.exact.review_id.eql(prepared.review_id));
    try std.testing.expect(preview.exact.identity.target.eql(&target));
    try std.testing.expectEqual(RunSummaryStatus.approved, preview.status);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, preview.exact.artifacts.draft_state);
    try std.testing.expect(preview.exact.artifacts.eql(artifacts));
    var draft_preview = try previewDeleteLocated(allocator, io, &configured, repository, located, sibling);
    defer draft_preview.deinit(allocator);
    try std.testing.expectEqual(RunSummaryStatus.draft, draft_preview.preview.status);
    const state_context: ReadStateContext = .{ .repository = repo, .repository_path = repo_path, .store_path = store_path_text };
    var before = try captureReadOnlyState(allocator, io, state_context);
    defer before.deinit(allocator);
    var mismatched = catalog.snapshot;
    mismatched.repository_instance_id.bytes[0] +%= 1;
    try std.testing.expectEqual(MaintenanceFailure.binding_changed, (try deleteRun(allocator, io, &configured, repository, .{ .store = mismatched, .review_id = prepared.review_id, .artifacts = artifacts })).failure);
    const deleted = try deleteRun(allocator, io, &configured, repository, .{ .store = catalog.snapshot, .review_id = prepared.review_id, .artifacts = artifacts });
    try std.testing.expectEqualDeep(DeleteResult{ .deleted = .complete }, deleted);
    var after = try captureReadOnlyState(allocator, io, state_context);
    defer after.deinit(allocator);
    inline for (.{ "head", "branch", "index", "local_config", "worktree" }) |field|
        try std.testing.expectEqualStrings(@field(before, field), @field(after, field));
    var remaining = try catalog_store.scan(allocator, io, configured.context(), instance_id);
    defer remaining.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), remaining.catalog.rows.len);
    try std.testing.expect(remaining.catalog.rows[0].review_id.eql(sibling));
    const other_run_name = try testRunDirectoryName(prepared.review_id);
    var other_run = try other_namespace.openDir(io, other_run_name.slice(), .{});
    other_run.close(io);
    var absent = try catalog_store.readExact(allocator, io, configured.context(), instance_id, prepared.review_id, null, null);
    defer absent.deinit(allocator);
    try std.testing.expect(absent == .absent);
    var missing_preview = try previewDeleteLocated(allocator, io, &configured, repository, located, prepared.review_id);
    defer missing_preview.deinit(allocator);
    try std.testing.expectEqual(MaintenanceFailure.not_found, missing_preview.failure);
    try std.testing.expectEqual(@as(usize, 0), (try cleanupTrash(allocator, io, &configured, repository, catalog.snapshot)).cleaned);
}

test "review store maintenance prune scan and sequential delete use a disposable Store" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    for ([_][]const []const u8{
        &.{ "git", "init", "--initial-branch=main" },
        &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture" },
    }) |argv| allocator.free(try runTestGit(io, repo, argv));
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    var repo_capability = try root_capability.RootCapability.openCanonical(repo_path);
    defer repo_capability.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const repository: RepositoryContext = .{ .capability = &repo_capability, .environment = &environment };
    var located_result = try repository_locator.locate(allocator, io, repository.git());
    defer located_result.deinit(allocator);
    const located = switch (located_result) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var configured = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer configured.deinit(allocator);
    const prepared = (try core.prepareBinding(allocator, io, configured.context(), .{
        .repository = located,
        .repository_context = repository.git(),
        .repository_name = "repo",
    })).success;
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_text = prepared.review_repository_id.canonical();
    var locks = try store.openDir(io, ".locks", .{});
    defer locks.close(io);
    try locks.createDir(io, &repository_text, .fromMode(0o700));
    var namespace = try store.openDir(io, prepared.repository_directory_name.slice(), .{});
    defer namespace.close(io);

    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const target: committed_review.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
    const unsafe_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oversized_id = try committed_review.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const malformed_id = try committed_review.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const older_id = try committed_review.ReviewId.parse("523e4567-e89b-42d3-a456-426614174000");
    const oldest_id = try committed_review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    const draft_id = try committed_review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, prepared.review_id, target, "2026-08-20T09:00:00Z", .completed);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, unsafe_id, target, "2026-08-20T08:00:00Z", .completed_unsafe_draft);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, oversized_id, target, "2026-08-20T07:00:00Z", .completed_oversized_draft);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, malformed_id, target, "2026-08-20T06:00:00Z", .completed_invalid_draft);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, older_id, target, "2026-08-20T05:00:00Z", .completed);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, oldest_id, target, "2026-08-20T04:00:00Z", .completed);
    try seedTestRun(allocator, io, namespace, prepared.review_repository_id, draft_id, target, "2026-08-20T03:00:00Z", .draft);

    const other_repository_id = try committed_review.ReviewRepositoryId.parse("823e4567-e89b-42d3-a456-426614174000");
    const other_display = try store_name.RepositoryDisplayName.fromStored("prune-other");
    const other_directory_name = store_name.RepositoryDirectoryName.format(&other_display, other_repository_id);
    try store.createDir(io, other_directory_name.slice(), .fromMode(0o700));
    var other_namespace = try store.openDir(io, other_directory_name.slice(), .{});
    defer other_namespace.close(io);
    try seedTestRun(allocator, io, other_namespace, other_repository_id, older_id, target, "2026-08-20T01:00:00Z", .completed);

    var first_scan = try scanMaintenanceLocated(allocator, io, &configured, repository, located);
    defer first_scan.deinit(allocator);
    const first = &first_scan.catalog;
    try std.testing.expectEqual(@as(usize, 7), first.rows.len);
    const unsafe_row = try maintenanceTestRow(first, unsafe_id);
    try std.testing.expectEqual(run.DraftSnapshotState.unsafe, unsafe_row.artifacts.draft_state);
    try std.testing.expect(unsafe_row.artifacts.draft_digest == null);
    const oversized_row = try maintenanceTestRow(first, oversized_id);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, oversized_row.artifacts.draft_state);
    try std.testing.expect(oversized_row.artifacts.draft_digest == null);
    const malformed_row = try maintenanceTestRow(first, malformed_id);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, malformed_row.artifacts.draft_state);
    try std.testing.expect(malformed_row.artifacts.draft_digest != null);
    try std.testing.expectEqual(try logicalTestRunBytes(io, namespace, malformed_id), malformed_row.logical_bytes);

    {
        const malformed_name = try testRunDirectoryName(malformed_id);
        var malformed_directory = try namespace.openDir(io, malformed_name.slice(), .{});
        defer malformed_directory.close(io);
        var retained_draft = try malformed_directory.openFile(io, "review_state.json", .{ .mode = .read_write });
        defer retained_draft.close(io);
        try retained_draft.setTimestampsNow(io);
    }
    var second_scan = try scanMaintenanceLocated(allocator, io, &configured, repository, located);
    defer second_scan.deinit(allocator);
    const second = &second_scan.catalog;
    try std.testing.expectEqual(first.rows.len, second.rows.len);
    try std.testing.expectEqual(malformed_row.created_at_unix, (try maintenanceTestRow(second, malformed_id)).created_at_unix);

    for ([_]committed_review.ReviewId{ malformed_id, older_id, oldest_id }) |id| {
        const row = try maintenanceTestRow(second, id);
        const deleted = try deleteRun(allocator, io, &configured, repository, .{
            .store = second.store,
            .review_id = id,
            .artifacts = row.artifacts,
        });
        try std.testing.expect(deleted == .deleted);
    }
    var remaining_scan = try scanMaintenanceLocated(allocator, io, &configured, repository, located);
    defer remaining_scan.deinit(allocator);
    const remaining = &remaining_scan.catalog;
    try std.testing.expectEqual(@as(usize, 4), remaining.rows.len);
    for ([_]committed_review.ReviewId{ prepared.review_id, unsafe_id, oversized_id, draft_id }) |id|
        _ = try maintenanceTestRow(remaining, id);
    const other_run_name = try testRunDirectoryName(older_id);
    var other_run = try other_namespace.openDir(io, other_run_name.slice(), .{});
    other_run.close(io);
}

fn maintenanceTestRow(catalog: *const MaintenanceCatalog, id: committed_review.ReviewId) !*const MaintenanceRow {
    for (catalog.rows) |*row| if (row.review_id.eql(id)) return row;
    return error.MissingFixtureRun;
}

fn logicalTestRunBytes(io: std.Io, namespace: std.Io.Dir, id: committed_review.ReviewId) !u64 {
    const directory_name = try testRunDirectoryName(id);
    var directory = try namespace.openDir(io, directory_name.slice(), .{});
    defer directory.close(io);
    var total: u64 = 0;
    inline for (.{ "manifest.json", "findings.json", "review_state.json", "result.json" }) |name|
        total = try std.math.add(u64, total, (try directory.statFile(io, name, .{})).size);
    return total;
}

fn seedTestRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: std.Io.Dir,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    created_at: []const u8,
    mode: TestRunMode,
) !void {
    const directory_name = try testRunDirectoryName(review_id);
    try namespace.createDir(io, directory_name.slice(), .fromMode(0o700));
    var directory = try namespace.openDir(io, directory_name.slice(), .{});
    defer directory.close(io);

    const producer: committed_review.Producer = .{ .name = "codex", .model = "gpt-test" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = created_at,
        .timing = .{ .duration_ms = 42 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = created_at,
        .display = .{ .base_label = "main~1", .head_label = "main" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    try writePrivate(io, directory, "manifest.json", manifest_bytes);
    try writePrivate(io, directory, "findings.json", findings_bytes);

    switch (mode) {
        .new => {},
        .draft, .invalid_result => {
            const draft: committed_review.ReviewDraftState = .{
                .schema_version = 1,
                .review_id = review_id,
                .target = target,
                .findings_digest = manifest.findings_digest,
                .revision = 1,
                .summary = null,
                .finding_dispositions = &.{},
                .anchored_notes = &.{},
            };
            const draft_bytes = try draft.writeCanonical(allocator);
            defer allocator.free(draft_bytes);
            try writePrivate(io, directory, "review_state.json", draft_bytes);
            if (mode == .invalid_result) try writePrivate(io, directory, "result.json", "{}\n");
        },
        .completed,
        .completed_needs_changes,
        .completed_canceled,
        .completed_invalid_draft,
        .completed_unsafe_draft,
        .completed_oversized_draft,
        => {
            const result: committed_review.RevisionReviewResult = .{
                .schema_version = 1,
                .review_id = review_id,
                .target = target,
                .findings_digest = manifest.findings_digest,
                .result = switch (mode) {
                    .completed_needs_changes => .needs_changes,
                    .completed_canceled => .canceled,
                    else => .approved,
                },
                .completed_at = "2026-08-20T09:00:00Z",
                .summary = if (mode == .completed_needs_changes) "Changes required." else null,
                .finding_dispositions = &.{},
                .anchored_notes = &.{},
            };
            const result_bytes = try result.writeCanonical(allocator);
            defer allocator.free(result_bytes);
            try writePrivate(io, directory, "result.json", result_bytes);
            if (mode == .completed_invalid_draft) {
                try writePrivate(io, directory, "review_state.json", "");
            } else if (mode == .completed_unsafe_draft) {
                try directory.symLink(io, "manifest.json", "review_state.json", .{});
            } else if (mode == .completed_oversized_draft) {
                var file = try directory.createFile(io, "review_state.json", .{ .permissions = .fromMode(0o600) });
                defer file.close(io);
                try file.setLength(io, committed_review.limits.max_artifact_bytes + 1);
            }
        },
        .unknown_entry => try writePrivate(io, directory, "unexpected.tmp", "x"),
    }
    const location_bytes = try run.writeLocationCanonicalAlloc(allocator, .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .directory_name = directory_name,
    });
    defer allocator.free(location_bytes);
    const location_name = store_path.RunLocationName.format(review_id);
    try writePrivate(io, namespace, location_name.slice(), location_bytes);
}

fn testRunDirectoryName(review_id: committed_review.ReviewId) !store_name.RunDirectoryName {
    var storage: [255]u8 = undefined;
    const review_text = review_id.canonical();
    const rendered = try std.fmt.bufPrint(&storage, "20260820-0800-main-{s}", .{review_text[0..8]});
    return store_name.RunDirectoryName.fromStored(rendered, review_id);
}

fn testSummary(history: *const History, review_id: committed_review.ReviewId) !*const RunSummary {
    for (history.rows) |*summary| {
        if (summary.review_id.eql(review_id)) return summary;
    }
    return error.ExpectedReviewSummary;
}

const FinalReadCase = enum { scan, exact, selection, delete_preview, maintenance_scan };
const FinalStoreDrift = enum { root, registry, namespace, lease };
const FinalRepositoryDrift = enum { marker, common_directory };

const FinalReadFixture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const ConfiguredStore,
    repository: RepositoryContext,
    located: *repository_locator.LocatedRepository,
    store: StoreSnapshot,
    review_id: committed_review.ReviewId,
    artifacts: ArtifactSnapshot,

    fn expectFailure(
        self: @This(),
        read: FinalReadCase,
        hook: BoundaryHook,
        scan_failure: ScanFailure,
        exact_failure: ReadFailure,
        selection_failure: SelectionFailure,
    ) !void {
        switch (read) {
            .scan => {
                var result = try scanWithHook(self.allocator, self.io, self.configured, self.repository, hook);
                defer result.deinit(self.allocator);
                try std.testing.expectEqual(scan_failure, result.failure);
            },
            .exact => {
                var result = try admitExactRunLocatedWithHook(
                    self.allocator,
                    self.io,
                    self.configured,
                    self.repository,
                    self.located,
                    self.review_id,
                    null,
                    hook,
                );
                defer result.deinit(self.allocator);
                try std.testing.expectEqual(exact_failure, result.failure);
            },
            .selection => {
                var result = try selectExactWithArtifactPolicy(
                    self.allocator,
                    self.io,
                    self.configured,
                    self.repository,
                    self.store,
                    self.review_id,
                    self.artifacts,
                    .strict,
                    hook,
                );
                defer result.deinit(self.allocator);
                try std.testing.expectEqual(selection_failure, result.failure);
            },
            .delete_preview => {
                var result = try previewDeleteLocatedWithHook(
                    self.allocator,
                    self.io,
                    self.configured,
                    self.repository,
                    self.located,
                    self.review_id,
                    hook,
                );
                defer result.deinit(self.allocator);
                try std.testing.expectEqual(MaintenanceFailure.binding_changed, result.failure);
            },
            .maintenance_scan => {
                var result = try scanMaintenanceLocatedWithHook(
                    self.allocator,
                    self.io,
                    self.configured,
                    self.repository,
                    self.located,
                    hook,
                );
                defer result.deinit(self.allocator);
                try std.testing.expectEqual(MaintenanceFailure.binding_changed, result.failure);
            },
        }
    }
};

const StoreBoundarySwap = struct {
    io: std.Io,
    parent: std.Io.Dir,
    store: std.Io.Dir,
    name: []const u8,
    replacement_registry: []const u8,
    mode: FinalStoreDrift,
    fired: bool = false,
    failure: ?anyerror = null,

    fn before(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.swap() catch |err| {
            self.failure = err;
            return;
        };
        self.fired = true;
    }

    fn swap(self: *@This()) !void {
        switch (self.mode) {
            .root => {
                try self.parent.rename("store", self.parent, ".admitted-store", self.io);
                try self.parent.createDir(self.io, "store", .fromMode(0o700));
            },
            .registry, .lease => {
                try self.store.rename("registry.json", self.store, ".admitted-registry", self.io);
                try self.store.writeFile(self.io, .{
                    .sub_path = "registry.json",
                    .data = self.replacement_registry,
                    .flags = .{ .permissions = .fromMode(0o600) },
                });
            },
            .namespace => {
                try self.store.rename(self.name, self.store, ".admitted-namespace", self.io);
                try self.store.createDir(self.io, self.name, .fromMode(0o700));
            },
        }
    }

    fn hook(self: *@This()) BoundaryHook {
        return .{ .context = self, .before_final_check = before };
    }

    fn restore(self: *@This()) !void {
        switch (self.mode) {
            .root => {
                try self.parent.deleteDir(self.io, "store");
                try self.parent.rename(".admitted-store", self.parent, "store", self.io);
            },
            .registry, .lease => {
                try self.store.deleteFile(self.io, "registry.json");
                try self.store.rename(".admitted-registry", self.store, "registry.json", self.io);
            },
            .namespace => {
                try self.store.deleteDir(self.io, self.name);
                try self.store.rename(".admitted-namespace", self.store, self.name, self.io);
            },
        }
    }
};

const RepositoryBoundarySwap = struct {
    io: std.Io,
    repository: std.Io.Dir,
    replacement: std.Io.Dir,
    original: committed_review.RepositoryInstanceId,
    mode: FinalRepositoryDrift,
    fired: bool = false,
    failure: ?anyerror = null,

    fn before(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.swap() catch |err| {
            self.failure = err;
            return;
        };
        self.fired = true;
    }

    fn replaceMarker(self: *@This(), bytes: []const u8) !void {
        try self.repository.deleteFile(self.io, ".git/gitframe/repository-id-v1");
        try self.repository.writeFile(self.io, .{
            .sub_path = ".git/gitframe/repository-id-v1",
            .data = bytes,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }

    fn swap(self: *@This()) !void {
        switch (self.mode) {
            .marker => try self.replaceMarker("923e4567-e89b-42d3-a456-426614174010\n"),
            .common_directory => {
                try self.repository.rename(".git", self.repository, ".admitted-git", self.io);
                try self.replacement.rename(".git", self.repository, ".git", self.io);
            },
        }
    }

    fn hook(self: *@This()) BoundaryHook {
        return .{ .context = self, .before_final_check = before };
    }

    fn restore(self: *@This()) !void {
        switch (self.mode) {
            .marker => {
                const canonical = self.original.canonical();
                var bytes: [37]u8 = undefined;
                @memcpy(bytes[0..36], &canonical);
                bytes[36] = '\n';
                try self.replaceMarker(&bytes);
            },
            .common_directory => {
                try self.repository.rename(".git", self.replacement, ".git", self.io);
                try self.repository.rename(".admitted-git", self.repository, ".git", self.io);
            },
        }
    }
};

test "Finding disposition exact reload keeps AI Review Store selection identity and no-scan behavior" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var output = try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    allocator.free(output);
    try repo.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    output = try runTestGit(io, repo, &.{ "git", "add", "file.txt" });
    allocator.free(output);
    output = try runTestGit(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    allocator.free(output);
    const base_output = try runTestGit(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_output);
    const base_text = try singleOutputLine(base_output);
    try repo.writeFile(io, .{ .sub_path = "file.txt", .data = "changed\n" });
    output = try runTestGit(io, repo, &.{ "git", "add", "file.txt" });
    allocator.free(output);
    output = try runTestGit(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    allocator.free(output);
    const head_output = try runTestGit(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_output);
    const head_text = try singleOutputLine(head_output);
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
        .head_oid = try committed_review.ObjectId.parse(.sha1, head_text),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
    };

    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    var repo_capability = try root_capability.RootCapability.openCanonical(repo_path);
    defer repo_capability.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const repository: RepositoryContext = .{ .capability = &repo_capability, .environment = &environment };
    var locator_result = try repository_locator.locate(allocator, io, repository.git());
    defer locator_result.deinit(allocator);
    const located = switch (locator_result) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    const instance_id = try located.ensureIdentity(allocator, io, .{});

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const repository_text = repository_id.canonical();
    const diagnostic = try @import("../review_store/registry.zig").diagnosticPath(located.canonical_path);
    const registry_bytes = try @import("../review_store/registry.zig").writeCanonicalAlloc(allocator, &.{.{
        .repository_instance_id = instance_id,
        .review_repository_id = repository_id,
        .repository_display_name = "repo",
        .directory_name = "repo-123e4567",
        .last_seen_path = diagnostic,
    }});
    defer allocator.free(registry_bytes);
    try writePrivate(io, store, "registry.json", registry_bytes);
    try store.createDir(io, "repo-123e4567", .fromMode(0o700));
    var namespace = try store.openDir(io, "repo-123e4567", .{});
    defer namespace.close(io);

    const valid_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const invalid_result_id = try committed_review.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const unknown_entry_id = try committed_review.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const unsafe_draft_id = try committed_review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    const new_id = try committed_review.ReviewId.parse("a23e4567-e89b-42d3-a456-426614174000");
    const draft_id = try committed_review.ReviewId.parse("b23e4567-e89b-42d3-a456-426614174000");
    const completed_id = try committed_review.ReviewId.parse("c23e4567-e89b-42d3-a456-426614174000");
    const needs_changes_id = try committed_review.ReviewId.parse("923e4567-e89b-42d3-a456-426614174000");
    const canceled_id = try committed_review.ReviewId.parse("f23e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, new_id, target, "2026-08-20T11:00:00Z", .new);
    try seedTestRun(allocator, io, namespace, repository_id, draft_id, target, "2026-08-20T10:00:00Z", .draft);
    try seedTestRun(allocator, io, namespace, repository_id, completed_id, target, "2026-08-20T09:00:00Z", .completed);
    try seedTestRun(allocator, io, namespace, repository_id, needs_changes_id, target, "2026-08-20T08:30:00Z", .completed_needs_changes);
    try seedTestRun(allocator, io, namespace, repository_id, canceled_id, target, "2026-08-20T08:15:00Z", .completed_canceled);
    try seedTestRun(allocator, io, namespace, repository_id, valid_id, target, "2026-08-20T08:00:00Z", .completed_invalid_draft);
    try seedTestRun(allocator, io, namespace, repository_id, invalid_result_id, target, "2026-08-20T07:00:00Z", .invalid_result);
    try seedTestRun(allocator, io, namespace, repository_id, unknown_entry_id, target, "2026-08-20T06:00:00Z", .unknown_entry);
    try seedTestRun(allocator, io, namespace, repository_id, unsafe_draft_id, target, "2026-08-20T04:00:00Z", .completed_unsafe_draft);

    const token = [_]u8{0xab} ** 16;
    const temp: store_path.NamespaceTempName = .{ .kind = .publish, .review_id = valid_id, .token = token };
    const temp_name = temp.format();
    try namespace.createDir(io, temp_name.slice(), .fromMode(0o700));
    const draft_temp: store_path.NamespaceTempName = .{ .kind = .draft, .review_id = valid_id, .token = token };
    const draft_temp_name = draft_temp.format();
    try writePrivate(io, namespace, draft_temp_name.slice(), "draft orphan");
    const result_temp: store_path.NamespaceTempName = .{ .kind = .result, .review_id = valid_id, .token = token };
    const result_temp_name = result_temp.format();
    try writePrivate(io, namespace, result_temp_name.slice(), "result orphan");
    try namespace.symLink(io, &repository_text, ".tmp-publish-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .{ .is_directory = true });
    try namespace.createDir(io, ".tmp-draft-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .fromMode(0o700));
    try namespace.symLink(io, &repository_text, ".tmp-result-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .{});
    try writePrivate(io, namespace, ".tmp-malformed", "x");

    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var scanned = try scanCompatibility(allocator, io, store_path_text, repository);
    defer scanned.deinit(allocator);
    const history = switch (scanned) {
        .history => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    try std.testing.expectEqual(@as(usize, 7), history.rows.len);
    try std.testing.expectEqual(RunSummaryStatus.new, (try testSummary(history, new_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.draft, (try testSummary(history, draft_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.approved, (try testSummary(history, completed_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.needs_changes, (try testSummary(history, needs_changes_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.canceled, (try testSummary(history, canceled_id)).status);
    const valid_row = try testSummary(history, valid_id);
    try std.testing.expectEqual(RunSummaryStatus.approved, valid_row.status);
    try std.testing.expectEqual(git_review.TargetAvailability.available, valid_row.availability);
    try std.testing.expectEqual(@as(u32, 0), valid_row.finding_count);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, valid_row.artifact_snapshot.draft_state);
    try std.testing.expectEqual(@as(usize, 3), history.orphan_count);
    try std.testing.expect(history.skipped_count >= 6);
    try std.testing.expectEqual(RunSummaryStatus.approved, (try testSummary(history, unsafe_draft_id)).status);

    var selected = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer selected.deinit(allocator);
    const selected_value = switch (selected) {
        .selected => |*owned| owned,
        .failure => return error.ExpectedSelectedReviewRun,
    };
    try std.testing.expect(selected_value.artifacts.state == .completed);
    try std.testing.expect(selected_value.artifacts.retained_draft_diagnostic == .invalid);
    try std.testing.expect(std.mem.indexOf(u8, selected_value.projection.patch_bytes, "+changed") != null);
    try std.testing.expect(selected_value.finding_projection.identity.review_repository_id.eql(repository_id));
    try std.testing.expect(selected_value.finding_projection.identity.review_id.eql(valid_id));
    try std.testing.expectEqual(@as(usize, 1), selected_value.finding_projection.files.len);
    try std.testing.expectEqual(@as(usize, 0), selected_value.finding_projection.entries.len);

    var configured = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer configured.deinit(allocator);
    var runtime_before = located.locator;
    runtime_before.device = 56;
    var runtime_after = runtime_before;
    runtime_after.device = 30;
    try repository_locator.testing.validateRuntime(runtime_before, instance_id, runtime_before, .{ .present = instance_id });
    try repository_locator.testing.validateRuntime(runtime_after, instance_id, runtime_after, .{ .present = instance_id });
    try std.testing.expectError(
        error.identity_conflict,
        repository_locator.testing.validateRuntime(runtime_before, instance_id, runtime_after, .{ .present = instance_id }),
    );

    try tmp.dir.createDir(io, "device-store", .fromMode(0o700));
    const device_store_path = try tmp.dir.realPathFileAlloc(io, "device-store", allocator);
    defer allocator.free(device_store_path);
    var device_store = try ConfiguredStore.initConfigured(allocator, device_store_path);
    defer device_store.deinit(allocator);
    var before_result = try repository_locator.locate(allocator, io, repository.git());
    defer before_result.deinit(allocator);
    const before = switch (before_result) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    before.locator = runtime_before;
    before.testing_runtime = runtime_before;
    const prepared_before = try prepareLocated(allocator, io, &device_store, repository.git(), before);
    const device_binding = switch (prepared_before) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const producer: committed_review.Producer = .{ .name = "device-seam", .model = "fixture" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = device_binding.review_id,
        .created_at = "2026-08-20T12:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const device_findings = try finding_set.writeCanonical(allocator);
    defer allocator.free(device_findings);
    const device_manifest_value: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = device_binding.review_id,
        .review_repository_id = device_binding.review_repository_id,
        .target = target,
        .created_at = "2026-08-20T12:00:00Z",
        .display = .{ .base_label = "main~1", .head_label = "main" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(device_findings),
    };
    const device_manifest = try device_manifest_value.writeCanonical(allocator);
    defer allocator.free(device_manifest);
    const device_published = try publishLocated(allocator, io, &device_store, repository, before, .{
        .repository_path = repo_path,
        .review_repository_id = device_binding.review_repository_id,
        .review_id = device_binding.review_id,
        .manifest_bytes = device_manifest,
        .findings_bytes = device_findings,
    });
    try std.testing.expect(device_published == .success);
    var scanned_before = try catalog_store.scan(allocator, io, device_store.context(), instance_id);
    defer scanned_before.deinit(allocator);
    const device_history_before = switch (scanned_before) {
        .catalog => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    try std.testing.expectEqual(@as(usize, 1), device_history_before.rows.len);
    try std.testing.expect(device_history_before.rows[0].review_id.eql(device_binding.review_id));

    var after_result = try repository_locator.locate(allocator, io, repository.git());
    defer after_result.deinit(allocator);
    const after = switch (after_result) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    after.locator = runtime_after;
    after.testing_runtime = runtime_after;
    try std.testing.expect(after.instanceId().?.eql(instance_id));
    try std.testing.expectEqual(core.BindingProbeResult.bound, try core.probeBinding(allocator, io, device_store.context(), after));
    var scanned_after = try catalog_store.scan(allocator, io, device_store.context(), instance_id);
    defer scanned_after.deinit(allocator);
    const device_history_after = switch (scanned_after) {
        .catalog => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    try std.testing.expect(device_history_after.snapshot.eql(device_history_before.snapshot));
    try std.testing.expectEqual(@as(usize, 1), device_history_after.rows.len);
    try std.testing.expect(device_history_after.rows[0].artifact_snapshot.eql(device_history_before.rows[0].artifact_snapshot));
    const prepared_after = try prepareLocated(allocator, io, &device_store, repository.git(), after);
    try std.testing.expect(prepared_after.success.review_repository_id.eql(device_binding.review_repository_id));
    try std.testing.expect(prepared_after.success.repository_directory_name.eql(&device_binding.repository_directory_name));
    var device_root = try capability.StoreRootCapability.openCanonical(device_store_path);
    defer device_root.deinit();
    var device_registry = try @import("../review_store/registry.zig").read(allocator, io, device_root.directory);
    defer device_registry.deinit();
    try std.testing.expectEqual(@as(usize, 1), device_registry.registry.bindings.len);
    var device_entries = device_root.directory.iterate();
    var device_namespaces: usize = 0;
    while (try device_entries.next(device_root.directory, io)) |entry| {
        if (!std.mem.eql(u8, entry.name, ".locks") and !std.mem.eql(u8, entry.name, "registry.json"))
            device_namespaces += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), device_namespaces);

    const replacement_id = try committed_review.ReviewRepositoryId.parse("e23e4567-e89b-42d3-a456-426614174000");
    const replacement_display = try store_name.RepositoryDisplayName.fromStored("replacement");
    const replacement_name = store_name.RepositoryDirectoryName.format(&replacement_display, replacement_id);
    const replacement_registry = try @import("../review_store/registry.zig").writeCanonicalAlloc(allocator, &.{.{
        .repository_instance_id = instance_id,
        .review_repository_id = replacement_id,
        .repository_display_name = replacement_display.slice(),
        .directory_name = replacement_name.slice(),
        .last_seen_path = diagnostic,
    }});
    defer allocator.free(replacement_registry);
    output = try runTestGit(io, tmp.dir, &.{ "cp", "-a", "repo", "lease-copy" });
    allocator.free(output);
    const lease_copy_path = try tmp.dir.realPathFileAlloc(io, "lease-copy/.git", allocator);
    defer allocator.free(lease_copy_path);
    const lease_diagnostic = try @import("../review_store/registry.zig").diagnosticPath(lease_copy_path);
    const lease_registry = try @import("../review_store/registry.zig").writeCanonicalAlloc(allocator, &.{.{
        .repository_instance_id = instance_id,
        .review_repository_id = repository_id,
        .repository_display_name = "repo",
        .directory_name = "repo-123e4567",
        .last_seen_path = lease_diagnostic,
    }});
    defer allocator.free(lease_registry);
    const scenarios = [_]struct { read: FinalReadCase, drift: FinalStoreDrift }{
        .{ .read = .scan, .drift = .root },
        .{ .read = .exact, .drift = .registry },
        .{ .read = .exact, .drift = .namespace },
        .{ .read = .selection, .drift = .root },
        .{ .read = .delete_preview, .drift = .registry },
        .{ .read = .maintenance_scan, .drift = .namespace },
        .{ .read = .scan, .drift = .lease },
        .{ .read = .exact, .drift = .lease },
        .{ .read = .selection, .drift = .lease },
        .{ .read = .delete_preview, .drift = .lease },
        .{ .read = .maintenance_scan, .drift = .lease },
    };
    const final_reads: FinalReadFixture = .{
        .allocator = allocator,
        .io = io,
        .configured = &configured,
        .repository = repository,
        .located = located,
        .store = history.snapshot,
        .review_id = valid_id,
        .artifacts = valid_row.artifact_snapshot,
    };
    for (scenarios) |scenario| {
        var drift: StoreBoundarySwap = .{
            .io = io,
            .parent = tmp.dir,
            .store = store,
            .name = history.snapshot.repository_directory_name.slice(),
            .replacement_registry = if (scenario.drift == .lease) lease_registry else replacement_registry,
            .mode = scenario.drift,
        };
        const hook = drift.hook();
        try final_reads.expectFailure(
            scenario.read,
            hook,
            if (scenario.drift == .lease) .identity_duplicate else .identity_conflict,
            .binding_changed,
            if (scenario.drift == .root) .root_drift else .binding_drift,
        );
        try std.testing.expect(drift.fired and drift.failure == null);
        try drift.restore();
    }
    try tmp.dir.createDir(io, "read-replacement", .fromMode(0o700));
    var read_replacement = try tmp.dir.openDir(io, "read-replacement", .{});
    defer read_replacement.close(io);
    output = try runTestGit(io, read_replacement, &.{ "git", "init", "--initial-branch=main" });
    allocator.free(output);
    for ([_]FinalRepositoryDrift{ .marker, .common_directory }) |mode| {
        for ([_]FinalReadCase{ .scan, .exact, .selection, .delete_preview, .maintenance_scan }) |read| {
            var drift: RepositoryBoundarySwap = .{
                .io = io,
                .repository = repo,
                .replacement = read_replacement,
                .original = instance_id,
                .mode = mode,
            };
            const hook = drift.hook();
            try final_reads.expectFailure(
                read,
                hook,
                .identity_conflict,
                .identity_conflict,
                .binding_drift,
            );
            try std.testing.expect(drift.fired and drift.failure == null);
            try drift.restore();
        }
    }

    try tmp.dir.createDir(io, "not-repository", .default_dir);
    var not_repository_directory = try tmp.dir.openDir(io, "not-repository", .{});
    defer not_repository_directory.close(io);
    try not_repository_directory.writeFile(io, .{
        .sub_path = ".git",
        .data = "gitdir: missing-git-directory\n",
    });
    const not_repository_path = try tmp.dir.realPathFileAlloc(io, "not-repository", allocator);
    defer allocator.free(not_repository_path);
    var not_repository_capability = try root_capability.RootCapability.openCanonical(not_repository_path);
    defer not_repository_capability.deinit();
    const not_repository: RepositoryContext = .{
        .capability = &not_repository_capability,
        .environment = &environment,
    };
    var repository_unavailable = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        not_repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer repository_unavailable.deinit(allocator);
    try std.testing.expect(repository_unavailable == .failure);
    try std.testing.expectEqual(SelectionFailure.repository_unavailable, repository_unavailable.failure);

    {
        var registry_file = try store.openFile(io, "registry.json", .{ .mode = .read_write });
        defer registry_file.close(io);
        try registry_file.setPermissions(io, .fromMode(0o640));
    }
    var unsafe_registry = try scanCompatibility(allocator, io, store_path_text, repository);
    defer unsafe_registry.deinit(allocator);
    try std.testing.expect(unsafe_registry == .failure);
    try std.testing.expectEqual(ScanFailure.registry_invalid, unsafe_registry.failure);
    {
        var registry_file = try store.openFile(io, "registry.json", .{ .mode = .read_write });
        defer registry_file.close(io);
        try registry_file.setPermissions(io, .fromMode(0o600));
    }

    try store.deleteFile(io, "registry.json");
    try writePrivate(io, store, "registry-target.json", registry_bytes);
    try store.symLink(io, "registry-target.json", "registry.json", .{});
    var symlink_registry = try scanCompatibility(allocator, io, store_path_text, repository);
    defer symlink_registry.deinit(allocator);
    try std.testing.expect(symlink_registry == .failure);
    try std.testing.expectEqual(ScanFailure.registry_invalid, symlink_registry.failure);
    try store.deleteFile(io, "registry.json");
    try store.deleteFile(io, "registry-target.json");
    try writePrivate(io, store, "registry.json", registry_bytes);

    var drifted_snapshot = history.snapshot;
    drifted_snapshot.root_inode +%= 1;
    var drifted = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        drifted_snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer drifted.deinit(allocator);
    try std.testing.expect(drifted == .failure);
    try std.testing.expectEqual(SelectionFailure.root_drift, drifted.failure);

    var missing_target = target;
    missing_target.head_oid = try committed_review.ObjectId.parse(.sha1, "ffffffffffffffffffffffffffffffffffffffff");
    const missing = try git_review.checkTargetAvailability(allocator, io, repository.git(), missing_target);
    try std.testing.expect(missing == .availability);
    try std.testing.expectEqual(git_review.TargetAvailability.missing, missing.availability);
    const missing_target_id = try committed_review.ReviewId.parse("823e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, missing_target_id, missing_target, "2026-08-20T03:00:00Z", .completed_invalid_draft);

    try repo.writeFile(io, .{
        .sub_path = "broken.commit",
        .data = "tree ffffffffffffffffffffffffffffffffffffffff\n" ++
            "author Test <test@example.invalid> 0 +0000\n" ++
            "committer Test <test@example.invalid> 0 +0000\n\n" ++
            "broken tree\n",
    });
    const broken_output = try runTestGit(io, repo, &.{ "git", "hash-object", "-t", "commit", "-w", "--literally", "broken.commit" });
    defer allocator.free(broken_output);
    const broken_text = try singleOutputLine(broken_output);
    const projection_failure_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = target.base_oid,
        .head_oid = try committed_review.ObjectId.parse(.sha1, broken_text),
        .diff_base_oid = target.diff_base_oid,
    };
    const projection_failure_id = try committed_review.ReviewId.parse("d23e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(
        allocator,
        io,
        namespace,
        repository_id,
        projection_failure_id,
        projection_failure_target,
        "2026-08-20T02:00:00Z",
        .completed,
    );
    var rescanned = try scanCompatibility(allocator, io, store_path_text, repository);
    defer rescanned.deinit(allocator);
    const history_with_missing = switch (rescanned) {
        .history => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    var missing_snapshot: ?run.ArtifactSnapshot = null;
    var projection_failure_snapshot: ?run.ArtifactSnapshot = null;
    for (history_with_missing.rows) |row| {
        if (row.review_id.eql(missing_target_id)) {
            try std.testing.expectEqual(git_review.TargetAvailability.missing, row.availability);
            missing_snapshot = row.artifact_snapshot;
        } else if (row.review_id.eql(projection_failure_id)) {
            try std.testing.expectEqual(git_review.TargetAvailability.available, row.availability);
            projection_failure_snapshot = row.artifact_snapshot;
        }
    }
    try std.testing.expect(missing_snapshot != null);
    try std.testing.expect(projection_failure_snapshot != null);
    var unavailable_selection = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history_with_missing.snapshot,
        missing_target_id,
        missing_snapshot.?,
    );
    defer unavailable_selection.deinit(allocator);
    try std.testing.expect(unavailable_selection == .failure);
    try std.testing.expectEqual(SelectionFailure.target_unavailable, unavailable_selection.failure);

    var projection_failed = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history_with_missing.snapshot,
        projection_failure_id,
        projection_failure_snapshot.?,
    );
    defer projection_failed.deinit(allocator);
    try std.testing.expect(projection_failed == .failure);
    try std.testing.expectEqual(SelectionFailure.projection_failed, projection_failed.failure);

    var binding_snapshot = history.snapshot;
    binding_snapshot.review_repository_id = try committed_review.ReviewRepositoryId.parse("923e4567-e89b-42d3-a456-426614174000");
    var binding_drift = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        binding_snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer binding_drift.deinit(allocator);
    try std.testing.expect(binding_drift == .failure);
    try std.testing.expectEqual(SelectionFailure.binding_drift, binding_drift.failure);

    const missing_store = try std.fs.path.join(allocator, &.{ store_path_text, "absent" });
    defer allocator.free(missing_store);
    var absent = try scanCompatibility(allocator, io, missing_store, repository);
    defer absent.deinit(allocator);
    try std.testing.expect(absent == .unbound);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(io, missing_store, .{}));

    const valid_location = valid_row.artifact_snapshot.run_location orelse
        return error.ExpectedRunLocation;
    var valid_directory = try namespace.openDir(
        io,
        valid_location.location.record.directory_name.slice(),
        .{},
    );
    defer valid_directory.close(io);
    const changed_result: committed_review.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = valid_id,
        .target = target,
        .findings_digest = selected_value.artifacts.manifest.value.findings_digest,
        .result = .approved,
        .completed_at = "2026-08-20T10:00:00Z",
        .summary = null,
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    const changed_result_bytes = try changed_result.writeCanonical(allocator);
    defer allocator.free(changed_result_bytes);
    try writePrivate(io, valid_directory, "result.json", changed_result_bytes);
    var exact_drift = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer exact_drift.deinit(allocator);
    try std.testing.expect(exact_drift == .failure);
    try std.testing.expectEqual(SelectionFailure.artifact_drift, exact_drift.failure);

    var reload_store = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer reload_store.deinit(allocator);
    var exact_reload = try selectExactReload(
        allocator,
        io,
        &reload_store,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer exact_reload.deinit(allocator);
    try std.testing.expect(exact_reload == .selected);
    const reloaded_snapshot = run.ArtifactSnapshot.fromLoaded(&exact_reload.selected.artifacts);
    try std.testing.expect(reloaded_snapshot.manifest_digest.eql(valid_row.artifact_snapshot.manifest_digest));
    try std.testing.expect(reloaded_snapshot.findings_digest.eql(valid_row.artifact_snapshot.findings_digest));
    try std.testing.expect(!reloaded_snapshot.eql(valid_row.artifact_snapshot));

    try writePrivate(io, valid_directory, "manifest.json", "{}\n");
    var invalid_artifact = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer invalid_artifact.deinit(allocator);
    try std.testing.expect(invalid_artifact == .failure);
    try std.testing.expectEqual(SelectionFailure.run_invalid, invalid_artifact.failure);

    const sha256_oid = try committed_review.ObjectId.parse(.sha256, "0000000000000000000000000000000000000000000000000000000000000000");
    const mismatched_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha256,
        .source_kind = .branch_range,
        .base_oid = sha256_oid,
        .head_oid = sha256_oid,
        .diff_base_oid = sha256_oid,
    };
    const mismatched_id = try committed_review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, mismatched_id, mismatched_target, "2026-08-20T05:00:00Z", .completed_invalid_draft);
    var mismatch_store = try capability.StoreRootCapability.openCanonical(store_path_text);
    defer mismatch_store.deinit();
    var mismatch_namespace = try mismatch_store.directory.openDirectory(history.snapshot.repository_directory_name.slice());
    defer mismatch_namespace.deinit();
    var mismatch_budget: run.ArtifactBudget = .{};
    var mismatch_loaded = try run.loadValidated(
        allocator,
        io,
        mismatch_namespace,
        repository_id,
        mismatched_id,
        &mismatch_budget,
    );
    defer mismatch_loaded.deinit(allocator);
    const mismatch_snapshot = switch (mismatch_loaded) {
        .loaded => |*loaded| run.ArtifactSnapshot.fromLoaded(loaded),
        .invalid => return error.ExpectedMismatchedObjectFormatRun,
    };
    var git_failed = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        mismatched_id,
        mismatch_snapshot,
    );
    defer git_failed.deinit(allocator);
    try std.testing.expect(git_failed == .failure);
    try std.testing.expectEqual(SelectionFailure.git_failed, git_failed.failure);
    var failed_scan = try scanCompatibility(allocator, io, store_path_text, repository);
    defer failed_scan.deinit(allocator);
    try std.testing.expect(failed_scan == .failure);
    try std.testing.expectEqual(ScanFailure.git_failed, failed_scan.failure);

    for (0..max_namespace_entries + 1) |index| {
        const name = try std.fmt.allocPrint(allocator, ".unknown-{d}", .{index});
        writePrivate(io, namespace, name, "x") catch |err| {
            allocator.free(name);
            return err;
        };
        allocator.free(name);
    }
    var over_limit = try scanCompatibility(allocator, io, store_path_text, repository);
    defer over_limit.deinit(allocator);
    try std.testing.expect(over_limit == .failure);
    try std.testing.expectEqual(ScanFailure.scan_limit_exceeded, over_limit.failure);

    // The generic identity read admits only the exact named child. More
    // unrelated entries than the scan bound above cannot redirect or exhaust
    // it, while the explicit catalog scan remains closed at its finite limit.
    try tmp.dir.createDir(io, "config-home", .fromMode(0o700));
    try tmp.dir.createDir(io, "config-home/gitframe", .fromMode(0o700));
    const config_bytes = try std.fmt.allocPrint(allocator, "[ai_review]\nstore_root = \"{s}\"\n", .{store_path_text});
    defer allocator.free(config_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "config-home/gitframe/config.toml", .data = config_bytes });
    const config_home = try tmp.dir.realPathFileAlloc(io, "config-home", allocator);
    defer allocator.free(config_home);
    var command_environment = std.process.Environ.Map.init(allocator);
    defer command_environment.deinit();
    try command_environment.put("XDG_CONFIG_HOME", config_home);

    // The drift/invalid-artifact checks above deliberately replaced this
    // manifest. Restore the admitted bytes before exercising the fresh reader.
    try writePrivate(io, valid_directory, "manifest.json", selected_value.artifacts.manifest_bytes);
    const read_state: ReadStateContext = .{
        .repository = repo,
        .repository_path = repo_path,
        .store_path = store_path_text,
    };

    // These fixture-owned mutations prove the comparator's sensitivity and
    // are fully restored before any product-read interval begins.
    try expectReadOnlyStateSensitivity(allocator, io, read_state);

    try expectExactResultPending(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        repository_id,
        new_id,
        target,
    );
    try expectExactResultPending(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        repository_id,
        draft_id,
        target,
    );
    for ([_]struct { id: committed_review.ReviewId, decision: committed_review.ReviewResultValue }{
        .{ .id = completed_id, .decision = .approved },
        .{ .id = needs_changes_id, .decision = .needs_changes },
        .{ .id = canceled_id, .decision = .canceled },
        // A valid result remains authoritative over an invalid or unsafe
        // retained draft and returns no draft bytes.
        .{ .id = valid_id, .decision = .approved },
        .{ .id = unsafe_draft_id, .decision = .approved },
    }) |case| {
        try expectExactResultDecision(
            allocator,
            io,
            read_state,
            &command_environment,
            repo_path,
            repository_id,
            case.id,
            target,
            case.decision,
        );
    }
    try expectExactResultFailure(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        invalid_result_id,
        null,
        .artifact_invalid,
    );
    try expectExactResultFailure(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        missing_target_id,
        null,
        .target_unavailable,
    );
    try expectExactResultFailure(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        try committed_review.ReviewId.parse("e23e4567-e89b-42d3-a456-426614174000"),
        null,
        .review_not_found,
    );

    var observed = try readExactIdentity(
        allocator,
        io,
        &command_environment,
        repo_path,
        new_id,
        null,
    );
    defer observed.deinit(allocator);
    const exact_identity = switch (observed) {
        .exact => |*value| value,
        .failure => return error.ExpectedExactIdentity,
    };
    try std.testing.expectEqual(Lifecycle.published, exact_identity.lifecycle);
    try std.testing.expect(exact_identity.review_id.eql(new_id));
    try std.testing.expectEqual(run.DraftSnapshotState.absent, exact_identity.artifacts.draft_state);

    var expected: ExpectedPublicationIdentity = .{
        .review_repository_id = exact_identity.identity.review_repository_id,
        .target = exact_identity.identity.target,
        .producer = .{
            .name = exact_identity.identity.producer_name,
            .model = exact_identity.identity.producer_model,
            .version = exact_identity.identity.producer_version,
            .skill_version = exact_identity.identity.producer_skill_version,
        },
        .created_at = &exact_identity.identity.created_at,
        .finding_count = exact_identity.identity.finding_count,
        .manifest_sha256 = exact_identity.identity.manifest_sha256,
        .findings_sha256 = exact_identity.identity.findings_sha256,
    };
    try expectExactIdentityMatch(allocator, io, &command_environment, repo_path, new_id, expected);

    expected.review_repository_id = try committed_review.ReviewRepositoryId.parse("823e4567-e89b-42d3-a456-426614174000");
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.review_repository_id = exact_identity.identity.review_repository_id;
    expected.target.base_oid = exact_identity.identity.target.head_oid;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.target = exact_identity.identity.target;
    expected.target.head_oid = exact_identity.identity.target.base_oid;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.target = exact_identity.identity.target;
    expected.target.diff_base_oid = exact_identity.identity.target.head_oid;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.target = mismatched_target;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.target = exact_identity.identity.target;
    expected.producer.name = "other";
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.producer.name = exact_identity.identity.producer_name;
    expected.producer.model = null;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.producer.model = exact_identity.identity.producer_model;
    expected.producer.version = "other";
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.producer.version = exact_identity.identity.producer_version;
    expected.producer.skill_version = "other";
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.producer.skill_version = exact_identity.identity.producer_skill_version;
    expected.created_at = "2026-08-20T11:00:01Z";
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.created_at = &exact_identity.identity.created_at;
    expected.finding_count +%= 1;
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.finding_count = exact_identity.identity.finding_count;
    expected.manifest_sha256 = committed_review.Sha256Digest.hash("other manifest");
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    expected.manifest_sha256 = exact_identity.identity.manifest_sha256;
    expected.findings_sha256 = committed_review.Sha256Digest.hash("other findings");
    try expectExactIdentityMismatch(allocator, io, &command_environment, repo_path, new_id, expected);
    try expectExactResultFailure(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        new_id,
        expected,
        .expected_mismatch,
    );

    // The public semantic context owns the same mutation use cases without
    // exposing a Store path or capability to App consumers.
    store.createDir(io, ".locks", .fromMode(0o700)) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    var locks = try store.openDir(io, ".locks", .{});
    defer locks.close(io);
    try locks.createDir(io, &repository_text, .fromMode(0o700));
    var configured_store = try ConfiguredStore.initConfigured(allocator, store_path_text);
    defer configured_store.deinit(allocator);
    const mutation_binding: ReviewRunBinding = .{
        .review_repository_id = exact_identity.identity.review_repository_id,
        .review_id = new_id,
        .target = exact_identity.identity.target,
        .findings_digest = exact_identity.identity.findings_sha256,
    };
    var saved = try saveDraft(allocator, io, &configured_store, repository, .{
        .binding = mutation_binding,
        .expected_revision = 0,
        .summary = "semantic context",
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    });
    defer saved.deinit(allocator);
    try std.testing.expect(saved == .committed);
    try std.testing.expectEqual(@as(u64, 1), saved.committed.revision);
    var completed = try createResult(allocator, io, &configured_store, repository, .{
        .binding = mutation_binding,
        .expected_revision = 1,
        .decision = .approved,
    });
    defer completed.deinit(allocator);
    try std.testing.expect(completed == .committed);
    try std.testing.expectEqual(@as(u64, 1), completed.committed.revision);
    try expectExactResultDecision(
        allocator,
        io,
        read_state,
        &command_environment,
        repo_path,
        repository_id,
        new_id,
        target,
        .approved,
    );

    try tmp.dir.rename("store", tmp.dir, "store-original", io);
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var root_replaced = try loadSelectionCompatibility(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer root_replaced.deinit(allocator);
    try std.testing.expect(root_replaced == .failure);
    try std.testing.expectEqual(SelectionFailure.root_drift, root_replaced.failure);
}

fn expectExactResultPending(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_context: ReadStateContext,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
) !void {
    var before = try captureReadOnlyState(allocator, io, state_context);
    defer before.deinit(allocator);
    var result = try readExactResult(allocator, io, environment, repository_path, review_id, null);
    defer result.deinit(allocator);
    const identity = switch (result) {
        .pending => |*value| value,
        .completed, .failure => return error.ExpectedPendingResult,
    };
    try std.testing.expect(identity.review_repository_id.eql(repository_id));
    try std.testing.expect(identity.review_id.eql(review_id));
    try std.testing.expect(identity.target.eql(&target));
    try std.testing.expectEqual(@as(u32, 0), identity.finding_count);
    var after = try captureReadOnlyState(allocator, io, state_context);
    defer after.deinit(allocator);
    try expectReadOnlyStateEqual(before, after);
}

fn expectExactResultDecision(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_context: ReadStateContext,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    decision: committed_review.ReviewResultValue,
) !void {
    var before = try captureReadOnlyState(allocator, io, state_context);
    defer before.deinit(allocator);
    var result = try readExactResult(allocator, io, environment, repository_path, review_id, null);
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |*value| value,
        .pending, .failure => return error.ExpectedCompletedResult,
    };
    try std.testing.expect(completed.identity.review_repository_id.eql(repository_id));
    try std.testing.expect(completed.identity.review_id.eql(review_id));
    try std.testing.expect(completed.identity.target.eql(&target));
    try std.testing.expectEqual(@as(u32, 0), completed.identity.finding_count);
    try std.testing.expect(completed.result_bytes.len > 0);
    try std.testing.expect(completed.result_bytes.len <= committed_review.limits.max_artifact_bytes);
    try std.testing.expect(committed_review.Sha256Digest.hash(completed.result_bytes).eql(completed.result_sha256));

    var parsed = try committed_review.RevisionReviewResult.parseStrict(allocator, completed.result_bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.review_id.eql(review_id));
    try std.testing.expect(parsed.value.target.eql(&target));
    try std.testing.expect(parsed.value.findings_digest.eql(completed.identity.findings_sha256));
    try std.testing.expectEqual(decision, parsed.value.result);
    const canonical = try parsed.value.writeCanonical(allocator);
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(completed.result_bytes, canonical);
    var after = try captureReadOnlyState(allocator, io, state_context);
    defer after.deinit(allocator);
    try expectReadOnlyStateEqual(before, after);
}

fn expectExactResultFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_context: ReadStateContext,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
    failure: ReadFailure,
) !void {
    var before = try captureReadOnlyState(allocator, io, state_context);
    defer before.deinit(allocator);
    var result = try readExactResult(allocator, io, environment, repository_path, review_id, expected);
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(failure, result.failure);
    var after = try captureReadOnlyState(allocator, io, state_context);
    defer after.deinit(allocator);
    try expectReadOnlyStateEqual(before, after);
}

fn expectExactIdentityMatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ExpectedPublicationIdentity,
) !void {
    var result = try readExactIdentity(allocator, io, environment, repository_path, review_id, expected);
    defer result.deinit(allocator);
    try std.testing.expect(result == .exact);
}

fn expectExactIdentityMismatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ExpectedPublicationIdentity,
) !void {
    var result = try readExactIdentity(allocator, io, environment, repository_path, review_id, expected);
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(ReadFailure.expected_mismatch, result.failure);
}

test "review run maintenance error mapping preserves new causes and legacy vocabularies" {
    try std.testing.expectEqual(MaintenanceFailure.permission_denied, maintenanceReadFailure(.permission_denied));
    try std.testing.expectEqual(MaintenanceFailure.io_failed, maintenanceReadFailure(.io_failed));
    try std.testing.expectEqual(MaintenanceFailure.conflict, maintenanceReadFailure(.concurrent_conflict));
    try std.testing.expectEqual(MaintenanceFailure.run_invalid, maintenanceReadFailure(.artifact_invalid));
    try std.testing.expectEqual(ReadFailure.store_unavailable, mapExactIdentityFailure(.permission_denied));
    try std.testing.expectEqual(ReadFailure.io_failed, mapExactIdentityFailure(.io_failed));
    try std.testing.expectEqual(ScanFailure.store_unavailable, mapCatalogScanFailure(.permission_denied));
    try std.testing.expectEqual(ScanFailure.store_invalid, mapCatalogScanFailure(.io_failed));
}

test "review run maintenance config failures stay distinct before Store mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGitDiscard(io, repo, &.{ "git", "init", "--initial-branch=main" });
    const repo_path = try repo.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(repo_path);
    try tmp.dir.createDir(io, "gitframe", .fromMode(0o700));
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_CONFIG_HOME", home);
    try environment.put("XDG_STATE_HOME", home);
    const id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    for ([_]MaintenanceFailure{ .permission_denied, .io_failed, .run_invalid }) |expected| {
        const path = "gitframe/config.toml";
        if (expected == .io_failed) {
            // A configuration symlink loop deterministically exercises read_failed.
            try tmp.dir.symLink(io, "config.toml", path, .{});
        } else {
            try tmp.dir.writeFile(io, .{ .sub_path = path, .data = if (expected == .run_invalid) "invalid = [" else "schema_version = 1\n" });
        }
        defer tmp.dir.deleteFile(io, path) catch unreachable;
        if (expected == .permission_denied) {
            var file = try tmp.dir.openFile(io, path, .{});
            defer file.close(io);
            try file.setPermissions(io, .fromMode(0o000));
        }
        var preview = try previewDelete(allocator, io, &environment, repo_path, id);
        defer preview.deinit(allocator);
        try std.testing.expectEqual(expected, preview.failure);
        try std.testing.expectEqual(expected, (try cleanupFromPath(allocator, io, &environment, repo_path)).failure);
        // Existing producer/read consumers keep their original public contract.
        try std.testing.expectEqual(PublicationFailure.store_invalid, (try prepare(allocator, io, &environment, repo_path)).failure);
        var legacy = try readExactIdentity(allocator, io, &environment, repo_path, id, null);
        defer legacy.deinit(allocator);
        try std.testing.expectEqual(ReadFailure.store_invalid, legacy.failure);
        try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "gitframe/ai-reviews", .{}));
    }
}
