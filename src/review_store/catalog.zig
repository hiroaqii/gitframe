//! Store-only bounded catalog scan and exact Review Run admission.
//!
//! This module knows no repository capability, Git command, diff, App, Review
//! page, or provider authority. Callers supply an already-derived physical
//! repository locator and compose Git object checks outside this boundary.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const capability = @import("capability.zig");
const core = @import("core.zig");
const store_name = @import("name.zig");
const registry = @import("registry.zig");
const run = @import("run.zig");
const store_path = @import("path.zig");

pub const max_namespace_entries: usize = 1024;
pub const max_run_candidates: usize = 512;
pub const max_enumerated_name_bytes: usize = 256 * 1024;
pub const max_diagnostics: usize = 8;
pub const max_diagnostic_bytes: usize = 256;

pub const StoreSnapshot = struct {
    root_device: u64,
    root_inode: u64,
    repository_locator: committed_review.GitCommonDirectoryLocator,
    review_repository_id: committed_review.ReviewRepositoryId,
    repository_display_name: store_name.RepositoryDisplayName,
    repository_directory_name: store_name.RepositoryDirectoryName,

    pub fn root(self: StoreSnapshot) core.RootSnapshot {
        return .{ .device = self.root_device, .inode = self.root_inode };
    }
};

pub const RunStatus = enum {
    new,
    draft,
    approved,
    needs_changes,
    canceled,
};

pub const CatalogRow = struct {
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    status: RunStatus,
    created_at: [20]u8,
    created_at_unix: i64,
    producer_name: []u8,
    producer_model: ?[]u8,
    producer_version: ?[]u8,
    producer_skill_version: ?[]u8,
    base_label: ?[]u8,
    head_label: ?[]u8,
    finding_count: u32,
    artifact_snapshot: run.ArtifactSnapshot,
    logical_bytes: u64,

    pub fn deinit(self: *CatalogRow, allocator: std.mem.Allocator) void {
        if (self.head_label) |value| allocator.free(value);
        if (self.base_label) |value| allocator.free(value);
        if (self.producer_skill_version) |value| allocator.free(value);
        if (self.producer_version) |value| allocator.free(value);
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }
};

pub const DiagnosticKind = enum {
    invalid_run,
    orphan_temp,
    unsafe_or_unknown_entry,
    retained_draft_invalid,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    text: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    snapshot: StoreSnapshot,
    rows: []CatalogRow,
    diagnostics: []Diagnostic,
    skipped_count: usize,
    orphan_count: usize,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const BoundEmpty = struct { snapshot: StoreSnapshot };

pub const ScanFailure = enum {
    permission_denied,
    io_failed,
    store_invalid,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    registry_invalid,
    registry_unavailable,
    namespace_invalid,
    enumeration_failed,
    scan_limit_exceeded,
};

pub const ScanResult = union(enum) {
    unbound,
    bound_empty: BoundEmpty,
    catalog: Catalog,
    failure: ScanFailure,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .catalog => |*value| value.deinit(allocator),
            .unbound, .bound_empty, .failure => {},
        }
        self.* = .unbound;
    }
};

/// Enumerate one already-bound repository namespace under finite limits.
/// Rows contain Store facts only and are ordered by exact Review ID.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    locator: committed_review.GitCommonDirectoryLocator,
) std.mem.Allocator.Error!ScanResult {
    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        .missing => return .unbound,
        .unavailable => return .{ .failure = .store_unavailable },
        .failure => |failure| return .{ .failure = mapOpenFailure(failure) },
    };
    defer opened.deinit();

    var registry_result = try registry.read(allocator, io, opened.root.directory);
    defer registry_result.deinit();
    const parsed_registry = switch (registry_result) {
        .missing => return .unbound,
        .registry => |*value| value,
        .invalid => return .{ .failure = .registry_invalid },
        .unavailable => |reason| return .{ .failure = switch (reason) {
            .permission_denied => .permission_denied,
            .io_failed => .io_failed,
        } },
    };
    const binding = parsed_registry.lookup(locator) orelse return .unbound;
    const repository_id = binding.review_repository_id;
    const snapshot = snapshotFrom(opened.snapshot, binding) catch
        return .{ .failure = .registry_invalid };
    var namespace = opened.root.directory.openDirectory(snapshot.repository_directory_name.slice()) catch |err| {
        return .{ .failure = if (err == error.FileNotFound)
            .namespace_invalid
        else
            classifyAccess(err, ScanFailure.namespace_invalid) };
    };
    defer namespace.deinit();

    var candidates: std.ArrayList(committed_review.ReviewId) = .empty;
    defer candidates.deinit(allocator);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &diagnostics);
    var entry_count: usize = 0;
    var name_bytes: usize = 0;
    var skipped_count: usize = 0;
    var orphan_count: usize = 0;
    var iterator = namespace.iterate();
    while (iterator.next(namespace, io) catch |err| return .{ .failure = classifyAccess(err, ScanFailure.enumeration_failed) }) |entry| {
        entry_count += 1;
        name_bytes = std.math.add(usize, name_bytes, entry.name.len) catch
            return .{ .failure = .scan_limit_exceeded };
        if (entry_count > max_namespace_entries or name_bytes > max_enumerated_name_bytes) {
            return .{ .failure = .scan_limit_exceeded };
        }
        if (committed_review.ReviewId.parse(entry.name)) |review_id| {
            if (candidates.items.len == max_run_candidates) {
                return .{ .failure = .scan_limit_exceeded };
            }
            try candidates.append(allocator, review_id);
            continue;
        } else |_| {}

        if (store_path.NamespaceTempName.parse(entry.name)) |temp| {
            const expected: capability.ExpectedKind = if (temp.kind == .publish) .directory else .regular_file;
            if (namespace.admitChild(entry.name, expected)) |_| {
                orphan_count += 1;
                try appendDiagnostic(allocator, &diagnostics, .orphan_temp, entry.name);
            } else |_| {
                skipped_count += 1;
                try appendDiagnostic(allocator, &diagnostics, .unsafe_or_unknown_entry, entry.name);
            }
        } else |_| {
            skipped_count += 1;
            try appendDiagnostic(allocator, &diagnostics, .unsafe_or_unknown_entry, entry.name);
        }
    }
    if (entry_count == 0) return .{ .bound_empty = .{ .snapshot = snapshot } };

    std.mem.sort(committed_review.ReviewId, candidates.items, {}, reviewIdLessThan);
    var rows: std.ArrayList(CatalogRow) = .empty;
    defer deinitRows(allocator, &rows);
    var artifact_budget: run.ArtifactBudget = .{};
    for (candidates.items) |review_id| {
        var loaded_result = try run.loadValidated(
            allocator,
            io,
            namespace,
            repository_id,
            review_id,
            &artifact_budget,
        );
        defer loaded_result.deinit(allocator);
        switch (loaded_result) {
            .loaded => |*loaded| {
                const logical_bytes = logicalArtifactBytes(loaded) orelse
                    return .{ .failure = .scan_limit_exceeded };
                const row = try rowFromLoaded(allocator, loaded, logical_bytes);
                rows.append(allocator, row) catch |err| {
                    var owned = row;
                    owned.deinit(allocator);
                    return err;
                };
                if (loaded.retained_draft_diagnostic != null) {
                    const text = review_id.canonical();
                    try appendDiagnostic(allocator, &diagnostics, .retained_draft_invalid, &text);
                }
            },
            .invalid => |reason| {
                if (reason == .scan_artifact_bytes_exceeded) {
                    return .{ .failure = .scan_limit_exceeded };
                }
                skipped_count += 1;
                const text = review_id.canonical();
                try appendDiagnostic(allocator, &diagnostics, .invalid_run, &text);
            },
        }
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
    return .{ .catalog = .{
        .snapshot = snapshot,
        .rows = owned_rows,
        .diagnostics = owned_diagnostics,
        .skipped_count = skipped_count,
        .orphan_count = orphan_count,
    } };
}

pub const ReadFailure = enum {
    permission_denied,
    io_failed,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    store_invalid,
    registry_invalid,
    registry_unavailable,
    namespace_invalid,
    artifact_invalid,
    root_changed,
    binding_changed,
    artifact_changed,
    concurrent_conflict,
};

pub const ExactRun = struct {
    root: core.OpenedRoot,
    snapshot: StoreSnapshot,
    artifacts: run.LoadedRunArtifacts,
    artifact_snapshot: run.ArtifactSnapshot,

    pub fn deinit(self: *ExactRun, allocator: std.mem.Allocator) void {
        self.artifacts.deinit(allocator);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const ReadResult = union(enum) {
    absent,
    exact: ExactRun,
    failure: ReadFailure,

    pub fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exact => |*value| value.deinit(allocator),
            .absent, .failure => {},
        }
        self.* = .absent;
    }
};

/// Admit only the named Run. This function never enumerates the repository
/// namespace and never substitutes another ID, order, timestamp, or mtime.
pub fn readExact(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    locator: committed_review.GitCommonDirectoryLocator,
    review_id: committed_review.ReviewId,
    expected_store: ?StoreSnapshot,
    expected_artifacts: ?run.ArtifactSnapshot,
) std.mem.Allocator.Error!ReadResult {
    return readExactWithHook(
        allocator,
        io,
        context,
        locator,
        review_id,
        expected_store,
        expected_artifacts,
        null,
    );
}

const ReadHook = struct {
    context: *anyopaque,
    after_admission: *const fn (*anyopaque) void,
};

fn readExactWithHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    locator: committed_review.GitCommonDirectoryLocator,
    review_id: committed_review.ReviewId,
    expected_store: ?StoreSnapshot,
    expected_artifacts: ?run.ArtifactSnapshot,
    hook: ?ReadHook,
) std.mem.Allocator.Error!ReadResult {
    if (expected_store) |expected| {
        if (!expected.repository_locator.eql(locator)) return .{ .failure = .binding_changed };
    }

    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        .missing => return if (expected_store == null) .absent else .{ .failure = .root_changed },
        .unavailable => return .{ .failure = .store_unavailable },
        .failure => |failure| return .{ .failure = mapReadOpenFailure(failure) },
    };
    var transferred = false;
    defer if (!transferred) opened.deinit();
    if (expected_store) |expected| {
        if (!opened.snapshot.eql(expected.root())) return .{ .failure = .root_changed };
    }

    var registry_result = try registry.read(allocator, io, opened.root.directory);
    defer registry_result.deinit();
    const parsed_registry = switch (registry_result) {
        .missing => return if (expected_store == null) .absent else .{ .failure = .binding_changed },
        .registry => |*value| value,
        .invalid => return .{ .failure = .registry_invalid },
        .unavailable => |reason| return .{ .failure = switch (reason) {
            .permission_denied => .permission_denied,
            .io_failed => .io_failed,
        } },
    };
    const binding = parsed_registry.lookup(locator) orelse
        return if (expected_store == null) .absent else .{ .failure = .binding_changed };
    const repository_id = binding.review_repository_id;
    if (expected_store) |expected| {
        if (!repository_id.eql(expected.review_repository_id)) {
            return .{ .failure = .binding_changed };
        }
    }
    const snapshot = snapshotFrom(opened.snapshot, binding) catch
        return .{ .failure = .registry_invalid };
    if (expected_store) |expected| {
        if (!snapshot.repository_display_name.eql(&expected.repository_display_name) or
            !snapshot.repository_directory_name.eql(&expected.repository_directory_name))
        {
            return .{ .failure = .binding_changed };
        }
    }

    var namespace = opened.root.directory.openDirectory(snapshot.repository_directory_name.slice()) catch |err| {
        return .{ .failure = if (err == error.FileNotFound)
            .namespace_invalid
        else
            classifyAccess(err, ReadFailure.namespace_invalid) };
    };
    defer namespace.deinit();
    const review_text = review_id.canonical();
    _ = namespace.admitChild(&review_text, .directory) catch |err| {
        return if (err == error.FileNotFound)
            if (expected_store == null) .absent else .{ .failure = .artifact_changed }
        else
            .{ .failure = classifyAccess(err, ReadFailure.artifact_invalid) };
    };

    var budget: run.ArtifactBudget = .{};
    var loaded_result = try run.loadValidated(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        &budget,
    );
    defer loaded_result.deinit(allocator);
    const loaded = switch (loaded_result) {
        .loaded => |*value| value,
        .invalid => |reason| return .{ .failure = loadFailure(reason) },
    };
    const artifact_snapshot = run.ArtifactSnapshot.fromLoaded(loaded);
    if (expected_artifacts) |expected| {
        if (!artifact_snapshot.eql(expected)) return .{ .failure = .artifact_changed };
    }

    if (hook) |observer| observer.after_admission(observer.context);
    if (try artifactsChangedAfterAdmission(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        artifact_snapshot,
    )) |failure| return .{ .failure = failure };
    if (try bindingChangedAfterAdmission(
        allocator,
        io,
        context,
        opened.snapshot,
        locator,
        repository_id,
        snapshot.repository_display_name,
        snapshot.repository_directory_name,
    )) |failure| return .{ .failure = failure };

    const artifacts = loaded.*;
    loaded_result = .{ .invalid = .artifact_invalid };
    transferred = true;
    return .{ .exact = .{
        .root = opened,
        .snapshot = snapshot,
        .artifacts = artifacts,
        .artifact_snapshot = artifact_snapshot,
    } };
}

fn bindingChangedAfterAdmission(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    expected_root: core.RootSnapshot,
    locator: committed_review.GitCommonDirectoryLocator,
    repository_id: committed_review.ReviewRepositoryId,
    repository_display_name: store_name.RepositoryDisplayName,
    repository_directory_name: store_name.RepositoryDirectoryName,
) std.mem.Allocator.Error!?ReadFailure {
    var current = switch (context.openExisting()) {
        .opened => |value| value,
        .missing => return .concurrent_conflict,
        .unavailable => return .store_unavailable,
        .failure => |failure| return mapReadOpenFailure(failure),
    };
    defer current.deinit();
    if (!current.snapshot.eql(expected_root)) return .concurrent_conflict;
    var registry_result = try registry.read(allocator, io, current.root.directory);
    defer registry_result.deinit();
    return switch (registry_result) {
        .missing => .concurrent_conflict,
        .registry => |*parsed| if (parsed.lookup(locator)) |found| blk: {
            if (!found.review_repository_id.eql(repository_id)) break :blk .concurrent_conflict;
            const display = store_name.RepositoryDisplayName.fromStored(found.repository_display_name) catch
                break :blk .registry_invalid;
            const directory = store_name.RepositoryDirectoryName.fromStored(
                found.directory_name,
                &display,
                found.review_repository_id,
            ) catch break :blk .registry_invalid;
            break :blk if (display.eql(&repository_display_name) and directory.eql(&repository_directory_name))
                null
            else
                .concurrent_conflict;
        } else .concurrent_conflict,
        .invalid => .registry_invalid,
        .unavailable => |reason| switch (reason) {
            .permission_denied => .permission_denied,
            .io_failed => .io_failed,
        },
    };
}

fn artifactsChangedAfterAdmission(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    admitted: run.ArtifactSnapshot,
) std.mem.Allocator.Error!?ReadFailure {
    var budget: run.ArtifactBudget = .{};
    var current = try run.loadValidated(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        &budget,
    );
    defer current.deinit(allocator);
    return switch (current) {
        .loaded => |*value| if (run.ArtifactSnapshot.fromLoaded(value).eql(admitted)) null else .concurrent_conflict,
        .invalid => |reason| switch (reason) {
            .permission_denied => .permission_denied,
            .io_failed => .io_failed,
            else => .concurrent_conflict,
        },
    };
}

fn mapOpenFailure(failure: core.OpenFailure) ScanFailure {
    return switch (failure) {
        .permission_denied => .permission_denied,
        .io_unavailable => .io_failed,
        .unsafe_authority, .invalid => .store_invalid,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
    };
}

fn mapReadOpenFailure(failure: core.OpenFailure) ReadFailure {
    return switch (failure) {
        .permission_denied => .permission_denied,
        .io_unavailable => .io_failed,
        .unsafe_authority, .invalid => .store_invalid,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
    };
}

fn classifyAccess(err: anyerror, comptime invalid: anytype) @TypeOf(invalid) {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.WrongType, error.WrongOwner, error.WrongMode, error.CrossDevice, error.MultipleLinks, error.SymLinkLoop, error.NotDir, error.FileSizeOutOfBounds, error.FileChangedWhileReading => invalid,
        else => .io_failed,
    };
}

fn loadFailure(reason: run.InvalidReason) ReadFailure {
    return switch (reason) {
        .permission_denied => .permission_denied,
        .io_failed => .io_failed,
        else => .artifact_invalid,
    };
}

fn snapshotFrom(
    root: core.RootSnapshot,
    binding: *const registry.Binding,
) error{InvalidBinding}!StoreSnapshot {
    const display = store_name.RepositoryDisplayName.fromStored(binding.repository_display_name) catch
        return error.InvalidBinding;
    const directory = store_name.RepositoryDirectoryName.fromStored(
        binding.directory_name,
        &display,
        binding.review_repository_id,
    ) catch return error.InvalidBinding;
    return .{
        .root_device = root.device,
        .root_inode = root.inode,
        .repository_locator = binding.locator,
        .review_repository_id = binding.review_repository_id,
        .repository_display_name = display,
        .repository_directory_name = directory,
    };
}

fn rowFromLoaded(
    allocator: std.mem.Allocator,
    loaded: *const run.LoadedRunArtifacts,
    logical_bytes: u64,
) std.mem.Allocator.Error!CatalogRow {
    const manifest = &loaded.manifest.value;
    var row: CatalogRow = .{
        .review_id = manifest.review_id,
        .target = manifest.target,
        .status = statusFromLoaded(loaded),
        .created_at = undefined,
        .created_at_unix = loaded.created_at_unix,
        .producer_name = try allocator.dupe(u8, manifest.producer.name),
        .producer_model = null,
        .producer_version = null,
        .producer_skill_version = null,
        .base_label = null,
        .head_label = null,
        .finding_count = manifest.finding_count,
        .artifact_snapshot = run.ArtifactSnapshot.fromLoaded(loaded),
        .logical_bytes = logical_bytes,
    };
    errdefer row.deinit(allocator);
    @memcpy(&row.created_at, manifest.created_at);
    if (manifest.producer.model) |value| row.producer_model = try allocator.dupe(u8, value);
    if (manifest.producer.version) |value| row.producer_version = try allocator.dupe(u8, value);
    if (manifest.producer.skill_version) |value| row.producer_skill_version = try allocator.dupe(u8, value);
    if (manifest.display) |display| {
        if (display.base_label) |value| row.base_label = try allocator.dupe(u8, value);
        if (display.head_label) |value| row.head_label = try allocator.dupe(u8, value);
    }
    return row;
}

fn logicalArtifactBytes(loaded: *const run.LoadedRunArtifacts) ?u64 {
    var total: u64 = 0;
    total = std.math.add(u64, total, std.math.cast(u64, loaded.manifest_bytes.len) orelse return null) catch return null;
    total = std.math.add(u64, total, std.math.cast(u64, loaded.findings_bytes.len) orelse return null) catch return null;
    if (loaded.draft_bytes) |bytes|
        total = std.math.add(u64, total, std.math.cast(u64, bytes.len) orelse return null) catch return null;
    if (loaded.result_bytes) |bytes|
        total = std.math.add(u64, total, std.math.cast(u64, bytes.len) orelse return null) catch return null;
    return total;
}

fn statusFromLoaded(loaded: *const run.LoadedRunArtifacts) RunStatus {
    if (loaded.result) |result| {
        return switch (result.value.result) {
            .approved => .approved,
            .needs_changes => .needs_changes,
            .canceled => .canceled,
        };
    }
    return switch (loaded.state) {
        .new => .new,
        .draft => .draft,
        .completed => unreachable,
    };
}

fn reviewIdLessThan(_: void, left: committed_review.ReviewId, right: committed_review.ReviewId) bool {
    const left_text = left.canonical();
    const right_text = right.canonical();
    return std.mem.lessThan(u8, &left_text, &right_text);
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    kind: DiagnosticKind,
    raw_name: []const u8,
) std.mem.Allocator.Error!void {
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
    for (raw[0..length], 0..) |byte, index| {
        value[index] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    }
    return value;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(CatalogRow)) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitDiagnostics(allocator: std.mem.Allocator, values: *std.ArrayList(Diagnostic)) void {
    for (values.items) |*value| value.deinit(allocator);
    values.deinit(allocator);
}

test "review store exact read is direct bounded and preserves lifecycle precedence without fallback" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const store_root = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_root);
    const locator: committed_review.GitCommonDirectoryLocator = .{ .device = 7, .inode = 11 };
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const repository_display_name = "repository";
    const repository_directory_name = "repository-123e4567";
    const diagnostic_path = try registry.diagnosticPath("/physical/repository");
    const bindings = [_]registry.Binding{.{
        .review_repository_id = repository_id,
        .repository_display_name = repository_display_name,
        .directory_name = repository_directory_name,
        .locator = locator,
        .canonical_path = diagnostic_path,
        .last_seen_path = diagnostic_path,
    }};
    const registry_bytes = try registry.writeCanonicalAlloc(allocator, &bindings);
    defer allocator.free(registry_bytes);
    try writePrivate(io, store, "registry.json", registry_bytes);
    try store.createDir(io, repository_directory_name, .fromMode(0o700));
    var namespace = try store.openDir(io, repository_directory_name, .{});
    defer namespace.close(io);

    const oid = try committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    const new_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const draft_id = try committed_review.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const result_id = try committed_review.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const invalid_draft_id = try committed_review.ReviewId.parse("523e4567-e89b-42d3-a456-426614174000");
    const invalid_result_id = try committed_review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    const absent_id = try committed_review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, new_id, target, "2026-08-24T00:00:00Z", .new);
    try seedTestRun(allocator, io, namespace, repository_id, draft_id, target, "2026-08-24T00:01:00Z", .draft);
    try seedTestRun(allocator, io, namespace, repository_id, result_id, target, "2026-08-24T00:02:00Z", .result_with_invalid_retained_draft);
    try seedTestRun(allocator, io, namespace, repository_id, invalid_draft_id, target, "2026-08-24T00:03:00Z", .invalid_active_draft);
    try seedTestRun(allocator, io, namespace, repository_id, invalid_result_id, target, "2026-08-24T00:04:00Z", .invalid_result);

    for (0..max_namespace_entries + 1) |index| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, ".unrelated-{d}", .{index});
        try namespace.createDir(io, name, .fromMode(0o700));
    }

    var context = try core.Context.initConfigured(allocator, store_root);
    defer context.deinit(allocator);
    var exact_result = try readExact(allocator, io, &context, locator, result_id, null, null);
    defer exact_result.deinit(allocator);
    const exact = switch (exact_result) {
        .exact => |*value| value,
        else => return error.ExpectedExactReviewRun,
    };
    try std.testing.expect(exact.artifacts.manifest.value.review_id.eql(result_id));
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, exact.artifacts.state);
    try std.testing.expectEqual(run.RetainedDraftDiagnostic.invalid, exact.artifacts.retained_draft_diagnostic.?);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, exact.artifact_snapshot.draft_state);
    try std.testing.expect(exact.artifact_snapshot.draft_digest != null);
    try std.testing.expect(exact.artifact_snapshot.result_digest != null);
    const expected_store = exact.snapshot;
    const expected_artifacts = exact.artifact_snapshot;

    var pinned = try readExact(
        allocator,
        io,
        &context,
        locator,
        result_id,
        expected_store,
        expected_artifacts,
    );
    defer pinned.deinit(allocator);
    try std.testing.expect(pinned == .exact);

    var changed_artifacts = expected_artifacts;
    changed_artifacts.manifest_digest.bytes[0] ^= 0xff;
    var artifact_changed = try readExact(
        allocator,
        io,
        &context,
        locator,
        result_id,
        expected_store,
        changed_artifacts,
    );
    defer artifact_changed.deinit(allocator);
    try std.testing.expectEqual(ReadFailure.artifact_changed, artifact_changed.failure);

    var wrong_root = expected_store;
    wrong_root.root_inode ^= 1;
    var root_changed = try readExact(
        allocator,
        io,
        &context,
        locator,
        result_id,
        wrong_root,
        expected_artifacts,
    );
    defer root_changed.deinit(allocator);
    try std.testing.expectEqual(ReadFailure.root_changed, root_changed.failure);

    var wrong_store = expected_store;
    wrong_store.review_repository_id = try committed_review.ReviewRepositoryId.parse("823e4567-e89b-42d3-a456-426614174000");
    var binding_changed = try readExact(
        allocator,
        io,
        &context,
        locator,
        result_id,
        wrong_store,
        expected_artifacts,
    );
    defer binding_changed.deinit(allocator);
    try std.testing.expectEqual(ReadFailure.binding_changed, binding_changed.failure);

    var absent = try readExact(allocator, io, &context, locator, absent_id, null, null);
    defer absent.deinit(allocator);
    try std.testing.expect(absent == .absent);
    var wrong_binding = try readExact(
        allocator,
        io,
        &context,
        .{ .device = locator.device, .inode = locator.inode + 1 },
        result_id,
        null,
        null,
    );
    defer wrong_binding.deinit(allocator);
    try std.testing.expect(wrong_binding == .absent);

    inline for (.{
        .{ new_id, committed_review.ReviewRunState.new },
        .{ draft_id, committed_review.ReviewRunState.draft },
    }) |expected| {
        var lifecycle = try readExact(allocator, io, &context, locator, expected[0], null, null);
        defer lifecycle.deinit(allocator);
        try std.testing.expectEqual(expected[1], lifecycle.exact.artifacts.state);
    }
    inline for (.{ invalid_draft_id, invalid_result_id }) |invalid_id| {
        var invalid = try readExact(allocator, io, &context, locator, invalid_id, null, null);
        defer invalid.deinit(allocator);
        try std.testing.expectEqual(ReadFailure.artifact_invalid, invalid.failure);
    }

    // A valid but unreadable file is operational failure, not an invalid Run.
    var registry_file = try store.openFile(io, "registry.json", .{ .mode = .read_write });
    defer registry_file.close(io);
    try registry_file.setPermissions(io, .fromMode(0o000));
    {
        defer registry_file.setPermissions(io, .fromMode(0o600)) catch unreachable;
        var denied = try readExact(allocator, io, &context, locator, result_id, null, null);
        defer denied.deinit(allocator);
        try std.testing.expectEqual(ReadFailure.permission_denied, denied.failure);
        var denied_scan = try scan(allocator, io, &context, locator);
        defer denied_scan.deinit(allocator);
        try std.testing.expectEqual(ScanFailure.permission_denied, denied_scan.failure);
        try std.testing.expectEqual(ReadFailure.permission_denied, (try bindingChangedAfterAdmission(
            allocator,
            io,
            &context,
            expected_store.root(),
            locator,
            repository_id,
            expected_store.repository_display_name,
            expected_store.repository_directory_name,
        )).?);
    }
    var selected_dir = try namespace.openDir(io, &result_id.canonical(), .{});
    defer selected_dir.close(io);
    var manifest_file = try selected_dir.openFile(io, "manifest.json", .{ .mode = .read_write });
    defer manifest_file.close(io);
    try manifest_file.setPermissions(io, .fromMode(0o000));
    {
        defer manifest_file.setPermissions(io, .fromMode(0o600)) catch unreachable;
        var denied = try readExact(allocator, io, &context, locator, result_id, null, null);
        defer denied.deinit(allocator);
        try std.testing.expectEqual(ReadFailure.permission_denied, denied.failure);
        var namespace_cap = try exact_result.exact.root.root.directory.openDirectory(repository_directory_name);
        defer namespace_cap.deinit();
        try std.testing.expectEqual(ReadFailure.permission_denied, (try artifactsChangedAfterAdmission(allocator, io, namespace_cap, repository_id, result_id, expected_artifacts)).?);
    }

    var over_limit = try scan(allocator, io, &context, locator);
    defer over_limit.deinit(allocator);
    try std.testing.expectEqual(ScanFailure.scan_limit_exceeded, over_limit.failure);
}

test "review history backend preserves open-error compatibility over the lossless core taxonomy" {
    const Case = struct {
        core_failure: core.OpenFailure,
        expected_scan: ScanFailure,
        expected_read: ReadFailure,
    };
    const cases = [_]Case{
        .{ .core_failure = .permission_denied, .expected_scan = .permission_denied, .expected_read = .permission_denied },
        .{ .core_failure = .io_unavailable, .expected_scan = .io_failed, .expected_read = .io_failed },
        .{ .core_failure = .unsafe_authority, .expected_scan = .store_invalid, .expected_read = .store_invalid },
        .{ .core_failure = .invalid, .expected_scan = .store_invalid, .expected_read = .store_invalid },
        .{ .core_failure = .unsupported_platform, .expected_scan = .unsupported_platform, .expected_read = .unsupported_platform },
        .{ .core_failure = .unsupported_filesystem, .expected_scan = .unsupported_filesystem, .expected_read = .unsupported_filesystem },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected_scan, mapOpenFailure(case.core_failure));
        try std.testing.expectEqual(case.expected_read, mapReadOpenFailure(case.core_failure));
    }
}

test "review store exact read closes post-admission replacements as concurrent conflict" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) {
        return error.SkipZigTest;
    }
    inline for (.{ PostAdmissionReplacement.root, .binding, .artifact }) |replacement| {
        try expectPostAdmissionConflict(replacement);
    }
}

const PostAdmissionReplacement = enum { root, binding, artifact };

const RaceHookState = struct {
    io: std.Io,
    parent: std.Io.Dir,
    store: std.Io.Dir,
    run_directory: std.Io.Dir,
    replacement: PostAdmissionReplacement,
    replacement_registry: []const u8,
    replacement_manifest: []const u8,
    replacement_findings: []const u8,
    failure: ?anyerror = null,

    fn afterAdmission(raw: *anyopaque) void {
        const self: *RaceHookState = @ptrCast(@alignCast(raw));
        self.replace() catch |err| {
            self.failure = err;
        };
    }

    fn replace(self: *RaceHookState) !void {
        switch (self.replacement) {
            .root => {
                try self.parent.rename("store", self.parent, "store-admitted", self.io);
                try self.parent.createDir(self.io, "store", .fromMode(0o700));
            },
            .binding => try writePrivate(
                self.io,
                self.store,
                "registry.json",
                self.replacement_registry,
            ),
            .artifact => {
                try writePrivate(
                    self.io,
                    self.run_directory,
                    "findings.json",
                    self.replacement_findings,
                );
                try writePrivate(
                    self.io,
                    self.run_directory,
                    "manifest.json",
                    self.replacement_manifest,
                );
            },
        }
    }
};

fn expectPostAdmissionConflict(replacement: PostAdmissionReplacement) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const store_root = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_root);

    const locator: committed_review.GitCommonDirectoryLocator = .{ .device = 7, .inode = 11 };
    const repository_id = try committed_review.ReviewRepositoryId.parse(
        "123e4567-e89b-42d3-a456-426614174000",
    );
    const replacement_repository_id = try committed_review.ReviewRepositoryId.parse(
        "223e4567-e89b-42d3-a456-426614174000",
    );
    const diagnostic_path = try registry.diagnosticPath("/physical/repository");
    const bindings = [_]registry.Binding{.{
        .review_repository_id = repository_id,
        .repository_display_name = "repository",
        .directory_name = "repository-123e4567",
        .locator = locator,
        .canonical_path = diagnostic_path,
        .last_seen_path = diagnostic_path,
    }};
    const registry_bytes = try registry.writeCanonicalAlloc(allocator, &bindings);
    defer allocator.free(registry_bytes);
    try writePrivate(io, store, "registry.json", registry_bytes);
    const replacement_bindings = [_]registry.Binding{.{
        .review_repository_id = replacement_repository_id,
        .repository_display_name = "repository",
        .directory_name = "repository-223e4567",
        .locator = locator,
        .canonical_path = diagnostic_path,
        .last_seen_path = diagnostic_path,
    }};
    const replacement_registry = try registry.writeCanonicalAlloc(
        allocator,
        &replacement_bindings,
    );
    defer allocator.free(replacement_registry);

    try store.createDir(io, "repository-123e4567", .fromMode(0o700));
    var namespace = try store.openDir(io, "repository-123e4567", .{});
    defer namespace.close(io);
    const review_id = try committed_review.ReviewId.parse(
        "323e4567-e89b-42d3-a456-426614174000",
    );
    const oid = try committed_review.ObjectId.parse(
        .sha1,
        "1111111111111111111111111111111111111111",
    );
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    try seedTestRun(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        target,
        "2026-08-24T00:00:00Z",
        .new,
    );
    const review_text = review_id.canonical();
    var run_directory = try namespace.openDir(io, &review_text, .{});
    defer run_directory.close(io);

    const producer: committed_review.Producer = .{
        .name = "codex",
        .model = "gpt-test",
        .version = "1.2.3",
        .skill_version = "utsuwa-review@1",
    };
    const replacement_findings_value: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-24T00:00:01Z",
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const replacement_findings = try replacement_findings_value.writeCanonical(allocator);
    defer allocator.free(replacement_findings);
    const replacement_manifest_value: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = "2026-08-24T00:00:01Z",
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(replacement_findings),
    };
    const replacement_manifest = try replacement_manifest_value.writeCanonical(allocator);
    defer allocator.free(replacement_manifest);

    var state: RaceHookState = .{
        .io = io,
        .parent = tmp.dir,
        .store = store,
        .run_directory = run_directory,
        .replacement = replacement,
        .replacement_registry = replacement_registry,
        .replacement_manifest = replacement_manifest,
        .replacement_findings = replacement_findings,
    };
    var context = try core.Context.initConfigured(allocator, store_root);
    defer context.deinit(allocator);
    var result = try readExactWithHook(
        allocator,
        io,
        &context,
        locator,
        review_id,
        null,
        null,
        .{ .context = &state, .after_admission = RaceHookState.afterAdmission },
    );
    defer result.deinit(allocator);
    if (state.failure) |err| return err;
    try std.testing.expectEqual(ReadFailure.concurrent_conflict, result.failure);
}

const TestRunMode = enum {
    new,
    draft,
    result_with_invalid_retained_draft,
    invalid_active_draft,
    invalid_result,
};

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

    const producer: committed_review.Producer = .{
        .name = "codex",
        .model = "gpt-test",
        .version = "1.2.3",
        .skill_version = "utsuwa-review@1",
    };
    const findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = created_at,
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try findings.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = created_at,
        .display = null,
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
        .draft => {
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
            const bytes = try draft.writeCanonical(allocator);
            defer allocator.free(bytes);
            try writePrivate(io, directory, "review_state.json", bytes);
        },
        .result_with_invalid_retained_draft => {
            const result: committed_review.RevisionReviewResult = .{
                .schema_version = 1,
                .review_id = review_id,
                .target = target,
                .findings_digest = manifest.findings_digest,
                .result = .approved,
                .completed_at = "2026-08-24T01:00:00Z",
                .summary = null,
                .finding_dispositions = &.{},
                .anchored_notes = &.{},
            };
            const bytes = try result.writeCanonical(allocator);
            defer allocator.free(bytes);
            try writePrivate(io, directory, "result.json", bytes);
            try writePrivate(io, directory, "review_state.json", "{}\n");
        },
        .invalid_active_draft => try writePrivate(io, directory, "review_state.json", "{}\n"),
        .invalid_result => try writePrivate(io, directory, "result.json", "{}\n"),
    }
}
