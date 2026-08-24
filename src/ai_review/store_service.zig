//! Product application boundary for AI Review Store use cases.
//!
//! This is the only production module that combines Store authority with a
//! physical repository capability, Git object checks, or committed projection.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const config = @import("../config.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const repository_locator = @import("../git/repository_locator.zig");
const root_capability = @import("../repo/root_capability.zig");
const catalog_store = @import("../review_store/catalog.zig");
const core = @import("../review_store/core.zig");
const run = @import("../review_store/run.zig");

const OpaqueStoreContext = opaque {};

pub const max_namespace_entries = catalog_store.max_namespace_entries;
pub const max_run_candidates = catalog_store.max_run_candidates;
pub const max_enumerated_name_bytes = catalog_store.max_enumerated_name_bytes;
pub const max_diagnostics = catalog_store.max_diagnostics;
pub const max_diagnostic_bytes = catalog_store.max_diagnostic_bytes;

/// Owned configuration-only Store address. Construction performs no Store IO,
/// and no path, descriptor, registry, or root accessor is public.
pub const ConfiguredStore = struct {
    state: *OpaqueStoreContext,

    pub fn init(
        allocator: std.mem.Allocator,
        configured: ?[]const u8,
        environment: ?*const std.process.Environ.Map,
    ) !ConfiguredStore {
        const context_ptr = try allocator.create(core.Context);
        errdefer allocator.destroy(context_ptr);
        context_ptr.* = try core.Context.init(allocator, configured, environment);
        return .{ .state = @ptrCast(context_ptr) };
    }

    pub fn initConfigured(
        allocator: std.mem.Allocator,
        configured: []const u8,
    ) !ConfiguredStore {
        const context_ptr = try allocator.create(core.Context);
        errdefer allocator.destroy(context_ptr);
        context_ptr.* = try core.Context.initConfigured(allocator, configured);
        return .{ .state = @ptrCast(context_ptr) };
    }

    pub fn clone(self: *const ConfiguredStore, allocator: std.mem.Allocator) std.mem.Allocator.Error!ConfiguredStore {
        const context_ptr = try allocator.create(core.Context);
        errdefer allocator.destroy(context_ptr);
        context_ptr.* = try self.context().clone(allocator);
        return .{ .state = @ptrCast(context_ptr) };
    }

    pub fn deinit(self: *ConfiguredStore, allocator: std.mem.Allocator) void {
        const context_ptr = self.contextMut();
        context_ptr.deinit(allocator);
        allocator.destroy(context_ptr);
        self.* = undefined;
    }

    fn context(self: *const ConfiguredStore) *const core.Context {
        return @ptrCast(@alignCast(self.state));
    }

    fn contextMut(self: *ConfiguredStore) *core.Context {
        return @ptrCast(@alignCast(self.state));
    }
};

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
    const located = try repository_locator.locate(allocator, io, repository.git());
    const locator = switch (located) {
        .locator => |value| value,
        .failure => return .{ .failure = .repository_invalid },
    };
    var scanned = try catalog_store.scan(allocator, io, store.context(), locator);
    defer scanned.deinit(allocator);
    const catalog_value = switch (scanned) {
        .unbound => return .unbound,
        .bound_empty => |value| return .{ .bound_empty = .{ .snapshot = value.snapshot } },
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

    pub fn deinit(self: *SelectedRunRead, allocator: std.mem.Allocator) void {
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

    const located = try repository_locator.locate(allocator, io, owned_context.git());
    const locator = switch (located) {
        .locator => |value| value,
        .failure => return .{ .failure = .repository_unavailable },
    };
    if (!locator.eql(expected.repository_locator)) return .{ .failure = .binding_drift };

    var exact_result = try catalog_store.readExact(
        allocator,
        io,
        configured_store.context(),
        locator,
        review_id,
        expected,
        expected_artifacts,
    );
    defer exact_result.deinit(allocator);
    const exact = switch (exact_result) {
        .exact => |*value| value,
        .absent => return .{ .failure = .run_invalid },
        .failure => |failure| return .{ .failure = mapExactSelectionFailure(failure) },
    };

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
    var projection_result = try git_review.materializeCommittedProjection(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
    );
    defer projection_result.deinit(allocator);
    const projection = switch (projection_result) {
        .projection => |value| value,
        .failure => return .{ .failure = .projection_failed },
    };

    const artifacts = exact.artifacts;
    exact.root.deinit();
    exact_result = .absent;
    projection_result = .{ .failure = .projection_git_command_failed };
    return .{ .selected = .{
        .snapshot = expected,
        .artifacts = artifacts,
        .projection = projection,
    } };
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

/// Generic no-write exact-ID use case. It freshly resolves repository and
/// Store authority, verifies both target objects, then compares the optional
/// complete immutable publication identity.
pub fn readExactIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?ExpectedPublicationIdentity,
) std.mem.Allocator.Error!ReadResult {
    var repository = switch (try openRepository(allocator, io, environment_map, repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = mapPublicationToReadFailure(failure) },
    };
    defer repository.deinit();

    var resolved = try resolveConfiguredStore(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const configured_store = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = mapPublicationToReadFailure(failure) },
    };
    var exact_result = try catalog_store.readExact(
        allocator,
        io,
        configured_store.context(),
        repository.locator,
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

pub const PublicationFailure = enum { invalid_artifact, target_unavailable, store_unavailable, unsupported_platform, unsupported_filesystem, duplicate_review_id, store_invalid, repository_invalid, git_failed, io_failed, binding_mismatch, concurrent_conflict };
pub const PrepareSuccess = struct { review_repository_id: committed_review.ReviewRepositoryId, review_id: committed_review.ReviewId };
pub const PrepareResult = union(enum) { success: PrepareSuccess, failure: PublicationFailure };
pub const PublishRequest = struct { repository_path: []const u8, review_repository_id: committed_review.ReviewRepositoryId, review_id: committed_review.ReviewId, manifest_bytes: []const u8, findings_bytes: []const u8 };
pub const PublishResult = union(enum) { success, failure: PublicationFailure };

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
        .failure => |failure| return .{ .failure = failure },
    };
    return switch (try core.prepareBinding(allocator, io, configured_store.context(), .{
        .locator = repository.locator,
        .repository_path = repository_path,
    })) {
        .success => |value| .{ .success = .{
            .review_repository_id = value.review_repository_id,
            .review_id = value.review_id,
        } },
        .failure => |failure| .{ .failure = mapPrepareCoreFailure(failure) },
    };
}

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
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

    var repository = switch (try openRepository(allocator, io, environment_map, request.repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer repository.deinit();
    const availability = try git_review.checkTargetAvailability(allocator, io, repository.git(), manifest.value.target);
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => |failure| return .{ .failure = switch (failure) {
            .invalid_repository => .repository_invalid,
            .invalid_target => .invalid_artifact,
            else => .git_failed,
        } },
    }

    var resolved = try resolveConfiguredStore(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const configured_store = switch (resolved) {
        .store => |*value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    return switch (try core.publish(allocator, io, configured_store.context(), .{
        .locator = repository.locator,
        .review_repository_id = request.review_repository_id,
        .review_id = request.review_id,
        .manifest_bytes = request.manifest_bytes,
        .findings_bytes = request.findings_bytes,
    })) {
        .success => .success,
        .failure => |failure| .{ .failure = mapPublishCoreFailure(failure) },
    };
}

const OwnedRepository = struct {
    root: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,
    locator: committed_review.GitCommonDirectoryLocator,

    fn deinit(self: *OwnedRepository) void {
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
        .locator => |locator| .{ .context = .{
            .root = root,
            .environment = environment,
            .locator = locator,
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
    failure: PublicationFailure,

    fn deinit(self: *ResolvedConfiguredStore, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .store => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .store_unavailable };
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
        .failure => return .{ .failure = .store_invalid },
    };
    const value = ConfiguredStore.init(allocator, configured, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .store_invalid },
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

fn deinitDiagnostics(allocator: std.mem.Allocator, values: *std.ArrayList(Diagnostic)) void {
    for (values.items) |*value| value.deinit(allocator);
    values.deinit(allocator);
}

fn mapExactSelectionFailure(failure: catalog_store.ReadFailure) SelectionFailure {
    return switch (failure) {
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
        .git_failed => .git_failed,
        .io_failed => .io_failed,
        .binding_mismatch => .binding_invalid,
        .concurrent_conflict => .concurrent_conflict,
        .invalid_artifact => .artifact_invalid,
        .target_unavailable => .target_unavailable,
        .duplicate_review_id => .io_failed,
    };
}

fn mapPrepareCoreFailure(failure: core.PrepareBindingFailure) PublicationFailure {
    return switch (failure) {
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .store_invalid => .store_invalid,
        .repository_invalid => .repository_invalid,
        .io_failed => .io_failed,
        .concurrent_conflict => .concurrent_conflict,
    };
}

fn mapPublishCoreFailure(failure: core.PublishFailure) PublicationFailure {
    return switch (failure) {
        .invalid_artifact => .invalid_artifact,
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
    try std.testing.expect(duplicate.context().openExisting() == .missing);
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
    try std.testing.expectEqual(@as(usize, 3), selected_fields.len);
    inline for (selected_fields, .{ "snapshot", "artifacts", "projection" }) |field, expected_name| {
        try std.testing.expectEqualStrings(expected_name, field.name);
        try std.testing.expect(field.type != @FieldType(core.OpenedRoot, "root"));
        try std.testing.expect(field.type != root_capability.RootCapability);
        try std.testing.expect(field.type != git_command.LocalGitEnvironment);
    }

    const own_source = try std.Io.Dir.cwd().readFileAlloc(io, "src/ai_review/store_service.zig", allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(own_source);
    const read_start = std.mem.indexOf(u8, own_source, "pub fn readExactIdentity(") orelse return error.MissingExactReader;
    const read_end = std.mem.indexOfPos(u8, own_source, read_start, "pub const PublicationFailure") orelse return error.MissingExactReaderEnd;
    const exact_reader = own_source[read_start..read_end];
    try std.testing.expect(std.mem.indexOf(u8, exact_reader, "catalog_store.readExact(") != null);
    inline for (.{ "catalog_store.scan(", "summaryLessThan", "std.mem.sort", "newest", "mtime" }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, exact_reader, forbidden) == null);
    }

    inline for (.{
        "src/app/load.zig",
        "src/app/pages/review.zig",
        "src/app/pages/review/coordinator.zig",
        "src/app/pages/review/view.zig",
        "src/ai_review/store_read_command.zig",
    }) |path| {
        const consumer = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(consumer);
        const production = applicationProductionPrefix(consumer);
        try std.testing.expect(std.mem.indexOf(u8, production, "review_store.history") == null);
        inline for (.{ "review_store/core.zig", "review_store/catalog.zig", "review_store/run.zig", "review_store/capability.zig" }) |raw_import| {
            try std.testing.expect(std.mem.indexOf(u8, production, raw_import) == null);
        }
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
const store_path = @import("../review_store/path.zig");

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
    const review_text = review_id.canonical();
    try namespace.createDir(io, &review_text, .fromMode(0o700));
    var directory = try namespace.openDir(io, &review_text, .{});
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
            }
        },
        .unknown_entry => try writePrivate(io, directory, "unexpected.tmp", "x"),
    }
}

fn testSummary(history: *const History, review_id: committed_review.ReviewId) !*const RunSummary {
    for (history.rows) |*summary| {
        if (summary.review_id.eql(review_id)) return summary;
    }
    return error.ExpectedReviewSummary;
}

test "AI Review Store application review history backend AI Reviews picker selection exact identity and no-scan behavior" {
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
    const locator_result = try repository_locator.locate(allocator, io, repository.git());
    const locator = switch (locator_result) {
        .locator => |value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const repository_text = repository_id.canonical();
    const registry_bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"bindings\":[{{\"review_repository_id\":\"{s}\",\"device\":\"{d}\",\"inode\":\"{d}\",\"canonical_path\":{{\"encoding\":\"utf8\",\"value\":\"{s}\"}},\"last_seen_path\":{{\"encoding\":\"utf8\",\"value\":\"{s}\"}}}}]}}\n", .{ &repository_text, locator.device, locator.inode, repo_path, repo_path });
    defer allocator.free(registry_bytes);
    try writePrivate(io, store, "registry.json", registry_bytes);
    try store.createDir(io, &repository_text, .fromMode(0o700));
    var namespace = try store.openDir(io, &repository_text, .{});
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

    const valid_text = valid_id.canonical();
    var valid_directory = try namespace.openDir(io, &valid_text, .{});
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
    var mismatch_namespace = try mismatch_store.directory.openDirectory(&repository_text);
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
