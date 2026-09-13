//! Configuration-only Review Store context and operation-scoped root admission.
//!
//! A `Context` is an owned address input. It never opens or creates Store
//! authority, and every operation must freshly admit its own root capability.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const durable = @import("../fs/durable.zig");
const capability = @import("capability.zig");
const mutation = @import("mutation.zig");
const maintenance = @import("maintenance.zig");
const store_name = @import("name.zig");
const registry = @import("registry.zig");
const run_store = @import("run.zig");
const store_path = @import("path.zig");

pub const UnavailableReason = store_path.Resolved.Unavailable;

pub const Context = struct {
    state: State,

    const State = union(enum) {
        configured: []u8,
        unavailable: UnavailableReason,
    };

    /// Resolve configuration without touching the filesystem.
    pub fn init(
        allocator: std.mem.Allocator,
        configured: ?[]const u8,
        environment: ?*const std.process.Environ.Map,
    ) (store_path.PathError || std.mem.Allocator.Error)!Context {
        var resolved = try store_path.resolveFromEnvironment(allocator, configured, environment);
        return takeResolved(&resolved);
    }

    /// Own one already-resolved value without opening its configured path.
    pub fn initResolved(
        allocator: std.mem.Allocator,
        resolved: *const store_path.Resolved,
    ) std.mem.Allocator.Error!Context {
        return switch (resolved.*) {
            .available => |value| .{ .state = .{ .configured = try allocator.dupe(u8, value) } },
            .unavailable => |reason| .{ .state = .{ .unavailable = reason } },
        };
    }

    /// Own one canonical configured Store address without opening it.
    pub fn initConfigured(
        allocator: std.mem.Allocator,
        configured: []const u8,
    ) (store_path.PathError || std.mem.Allocator.Error)!Context {
        try store_path.validateAbsoluteCanonical(configured);
        return .{ .state = .{ .configured = try allocator.dupe(u8, configured) } };
    }

    pub fn clone(self: *const Context, allocator: std.mem.Allocator) std.mem.Allocator.Error!Context {
        return switch (self.state) {
            .configured => |value| .{ .state = .{ .configured = try allocator.dupe(u8, value) } },
            .unavailable => |reason| .{ .state = .{ .unavailable = reason } },
        };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .configured => |value| allocator.free(value),
            .unavailable => {},
        }
        self.* = .{ .state = .{ .unavailable = .no_state_home } };
    }

    /// Freshly open existing Store authority. Missing configured authority is
    /// distinct from unavailable configuration and never creates the root.
    pub fn openExisting(self: *const Context) OpenResult {
        const configured = switch (self.state) {
            .configured => |value| value,
            .unavailable => |reason| return .{ .unavailable = reason },
        };
        const root = capability.StoreRootCapability.openCanonical(configured) catch |err|
            return classifyOpenError(err);
        return .{ .opened = .{
            .root = root,
            .snapshot = .{
                .device = root.directory.metadata.device,
                .inode = root.directory.metadata.inode,
            },
        } };
    }

    /// Borrow the configured address only for Store implementation modules.
    /// Application/public facades must retain the `Context` instead.
    fn configuredPath(self: *const Context) ?[]const u8 {
        return switch (self.state) {
            .configured => |value| value,
            .unavailable => null,
        };
    }

    fn takeResolved(resolved: *store_path.Resolved) Context {
        return switch (resolved.*) {
            .available => |value| blk: {
                resolved.* = .{ .unavailable = .no_state_home };
                break :blk .{ .state = .{ .configured = value } };
            },
            .unavailable => |reason| .{ .state = .{ .unavailable = reason } },
        };
    }
};

pub const RootSnapshot = struct {
    device: u64,
    inode: u64,

    pub fn eql(self: RootSnapshot, other: RootSnapshot) bool {
        return self.device == other.device and self.inode == other.inode;
    }
};

/// Operation-scoped descriptor owner. It must never be cached in `Context`.
pub const OpenedRoot = struct {
    root: capability.StoreRootCapability,
    snapshot: RootSnapshot,

    pub fn deinit(self: *OpenedRoot) void {
        self.root.deinit();
        self.* = undefined;
    }
};

pub const OpenFailure = enum {
    permission_denied,
    io_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    unsafe_authority,
    invalid,
};

pub const OpenResult = union(enum) {
    opened: OpenedRoot,
    missing,
    unavailable: UnavailableReason,
    failure: OpenFailure,

    pub fn deinit(self: *OpenResult) void {
        switch (self.*) {
            .opened => |*value| value.deinit(),
            .missing, .unavailable, .failure => {},
        }
        self.* = .missing;
    }
};

pub const PrepareBindingFailure = enum {
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    store_invalid,
    repository_invalid,
    repository_name_invalid,
    repository_namespace_collision,
    io_failed,
    concurrent_conflict,
};

pub const PrepareBindingRequest = struct {
    locator: committed_review.GitCommonDirectoryLocator,
    repository_path: []const u8,
    repository_name: ?[]const u8 = null,
};

pub const PrepareBindingSuccess = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    repository_display_name: store_name.RepositoryDisplayName,
    repository_directory_name: store_name.RepositoryDirectoryName,
};

pub const PrepareBindingResult = union(enum) {
    success: PrepareBindingSuccess,
    failure: PrepareBindingFailure,
};

pub const BindingProbeResult = union(enum) {
    bound,
    unbound,
    failure: PrepareBindingFailure,
};

/// Read-only preflight used to avoid rediscovering a main-worktree name for an
/// already-bound physical repository. Missing Store/registry means unbound.
pub fn probeBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    locator: committed_review.GitCommonDirectoryLocator,
) std.mem.Allocator.Error!BindingProbeResult {
    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        .missing => return .unbound,
        .unavailable => return .{ .failure = .store_unavailable },
        .failure => |failure| return .{ .failure = switch (failure) {
            .unsupported_platform => .unsupported_platform,
            .unsupported_filesystem => .unsupported_filesystem,
            .unsafe_authority, .invalid => .store_invalid,
            .permission_denied, .io_unavailable => .store_unavailable,
        } },
    };
    defer opened.deinit();
    var current = try registry.read(allocator, io, opened.root.directory);
    defer current.deinit();
    return switch (current) {
        .missing => .unbound,
        .registry => |*parsed| if (parsed.lookup(locator) == null) .unbound else .bound,
        .invalid => .{ .failure = .store_invalid },
        .unavailable => .{ .failure = .store_unavailable },
    };
}

/// The only Store core operation allowed to create the configured root,
/// repository namespace, and registry binding. It never creates a Run.
pub fn prepareBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: PrepareBindingRequest,
) std.mem.Allocator.Error!PrepareBindingResult {
    return prepareBindingWithObserver(allocator, io, context, request, .{});
}

fn prepareBindingWithObserver(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: PrepareBindingRequest,
    observer: durable.Observer,
) std.mem.Allocator.Error!PrepareBindingResult {
    const configured = context.configuredPath() orelse
        return .{ .failure = .store_unavailable };
    var root = capability.StoreRootCapability.openOrCreateCanonical(io, configured) catch |err| {
        return .{ .failure = mapPrepareOpenError(err) };
    };
    defer root.deinit();
    var locks = acquireDirectory(io, root.directory, ".locks", .{}) catch |err| {
        return .{ .failure = mapPrepareMutationError(err) };
    };
    defer locks.deinit();
    var lock = acquireLock(io, locks, "registry.lock", .wait) catch |err| {
        return .{ .failure = mapPrepareMutationError(err) };
    };
    defer lock.deinit();

    var current = try registry.read(allocator, io, root.directory);
    defer current.deinit();
    const existing = switch (current) {
        .missing => null,
        .registry => |*value| value,
        .invalid => return .{ .failure = .store_invalid },
        .unavailable => return .{ .failure = .store_unavailable },
    };

    const diagnostic_path = registry.diagnosticPath(request.repository_path) catch
        return .{ .failure = .repository_invalid };
    var repository_id: committed_review.ReviewRepositoryId = undefined;
    var repository_display_name: store_name.RepositoryDisplayName = undefined;
    var repository_directory_name: store_name.RepositoryDirectoryName = undefined;
    var replacement_needed = false;
    var created_namespace: ?capability.DirectoryCapability = null;
    defer if (created_namespace) |*directory| directory.deinit();
    var bindings_owner: ?[]registry.Binding = null;
    defer if (bindings_owner) |owned| allocator.free(owned);
    var bindings: []registry.Binding = undefined;
    if (existing) |parsed| {
        const adding_binding = parsed.lookup(request.locator) == null;
        if (adding_binding and parsed.bindings.len == registry.max_bindings) {
            return .{ .failure = .store_invalid };
        }
        bindings = try allocator.alloc(
            registry.Binding,
            parsed.bindings.len + @intFromBool(adding_binding),
        );
        bindings_owner = bindings;
        @memcpy(bindings[0..parsed.bindings.len], parsed.bindings);
        if (parsed.lookup(request.locator)) |found| {
            repository_id = found.review_repository_id;
            repository_display_name = store_name.RepositoryDisplayName.fromStored(found.repository_display_name) catch
                return .{ .failure = .store_invalid };
            repository_directory_name = store_name.RepositoryDirectoryName.fromStored(
                found.directory_name,
                &repository_display_name,
                repository_id,
            ) catch return .{ .failure = .store_invalid };
            var namespace = root.directory.openDirectory(repository_directory_name.slice()) catch
                return .{ .failure = .store_invalid };
            namespace.deinit();
            for (bindings[0..parsed.bindings.len]) |*binding| {
                if (!binding.locator.eql(request.locator)) continue;
                if (!std.mem.eql(u8, binding.last_seen_path.bytes, request.repository_path)) {
                    binding.last_seen_path = diagnostic_path;
                    replacement_needed = true;
                }
                break;
            }
        } else {
            repository_display_name = store_name.RepositoryDisplayName.fromMainWorktreeBasename(
                request.repository_name orelse return .{ .failure = .repository_name_invalid },
            ) catch return .{ .failure = .repository_name_invalid };
            repository_id = generateRepositoryId(io) catch return .{ .failure = .io_failed };
            repository_directory_name = store_name.RepositoryDirectoryName.format(&repository_display_name, repository_id);
            for (parsed.bindings) |binding| {
                if (std.mem.eql(u8, binding.directory_name, repository_directory_name.slice())) {
                    return .{ .failure = .repository_namespace_collision };
                }
            }
            bindings[bindings.len - 1] = .{
                .review_repository_id = repository_id,
                .repository_display_name = repository_display_name.slice(),
                .directory_name = repository_directory_name.slice(),
                .locator = request.locator,
                .canonical_path = diagnostic_path,
                .last_seen_path = diagnostic_path,
            };
            std.mem.sort(registry.Binding, bindings, {}, bindingLessThan);
            replacement_needed = true;
        }
    } else {
        repository_display_name = store_name.RepositoryDisplayName.fromMainWorktreeBasename(
            request.repository_name orelse return .{ .failure = .repository_name_invalid },
        ) catch return .{ .failure = .repository_name_invalid };
        repository_id = generateRepositoryId(io) catch return .{ .failure = .io_failed };
        repository_directory_name = store_name.RepositoryDirectoryName.format(&repository_display_name, repository_id);
        bindings = try allocator.alloc(registry.Binding, 1);
        bindings_owner = bindings;
        bindings[0] = .{
            .review_repository_id = repository_id,
            .repository_display_name = repository_display_name.slice(),
            .directory_name = repository_directory_name.slice(),
            .locator = request.locator,
            .canonical_path = diagnostic_path,
            .last_seen_path = diagnostic_path,
        };
        replacement_needed = true;
    }

    if (replacement_needed) {
        const previous_bytes = if (existing) |parsed|
            registry.writeCanonicalAlloc(allocator, parsed.bindings) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failure = .store_invalid },
            }
        else
            null;
        defer if (previous_bytes) |bytes| allocator.free(bytes);
        const bytes = registry.writeCanonicalAlloc(allocator, bindings) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = .store_invalid },
        };
        defer allocator.free(bytes);

        const is_new_binding = existing == null or existing.?.lookup(request.locator) == null;
        if (is_new_binding) {
            const created = switch (capability.createDirectory(
                io,
                root.directory,
                repository_directory_name.slice(),
                observer,
            )) {
                .not_completed => |err| return .{ .failure = mapRepositoryNamespaceCreateError(err) },
                .completed => |result| result,
            };
            const namespace = root.directory.openDirectory(repository_directory_name.slice()) catch
                return .{ .failure = .concurrent_conflict };
            created_namespace = namespace;
            if (created.after_error) |err| {
                cleanupOwnedEmptyNamespace(io, root.directory, repository_directory_name.slice(), namespace.metadata);
                return .{ .failure = mapPrepareMutationError(err) };
            }
            switch (capability.syncDirectory(io, root.directory, observer)) {
                .not_completed => |err| {
                    cleanupOwnedEmptyNamespace(io, root.directory, repository_directory_name.slice(), namespace.metadata);
                    return .{ .failure = mapPrepareMutationError(err) };
                },
                .completed => |result| if (result.after_error) |err| {
                    cleanupOwnedEmptyNamespace(io, root.directory, repository_directory_name.slice(), namespace.metadata);
                    return .{ .failure = mapPrepareMutationError(err) };
                },
            }
        }

        const replacement = atomicReplaceRegistry(io, root.directory, bytes, observer);
        const readback = registryReadback(allocator, io, root.directory, bytes, previous_bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .concurrent_conflict };
        };
        switch (readback) {
            .candidate => switch (replacement) {
                .committed => |after_error| if (after_error) |err| return .{ .failure = mapPrepareMutationError(err) },
                .not_committed => |err| return .{ .failure = mapPrepareMutationError(err) },
            },
            .previous => {
                if (created_namespace) |namespace| cleanupOwnedEmptyNamespace(
                    io,
                    root.directory,
                    repository_directory_name.slice(),
                    namespace.metadata,
                );
                return .{ .failure = switch (replacement) {
                    .not_committed => |err| if (err == error.ConcurrentStagingConflict)
                        .concurrent_conflict
                    else
                        mapPrepareMutationError(err),
                    .committed => .concurrent_conflict,
                } };
            },
            .ambiguous => return .{ .failure = .concurrent_conflict },
        }
    }

    const review_id = generateReviewId(io) catch return .{ .failure = .io_failed };
    return .{ .success = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .repository_display_name = repository_display_name,
        .repository_directory_name = repository_directory_name,
    } };
}

pub const PublishFailure = enum {
    invalid_artifact,
    target_label_invalid,
    local_time_unavailable,
    run_name_collision,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    duplicate_review_id,
    store_invalid,
    io_failed,
    binding_mismatch,
    concurrent_conflict,
};

pub const PublishRequest = struct {
    locator: committed_review.GitCommonDirectoryLocator,
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    manifest_bytes: []const u8,
    findings_bytes: []const u8,
};

pub const PublishResult = union(enum) {
    success,
    failure: PublishFailure,
};

/// Publish one already-validated immutable Run under an exact existing
/// locator binding. This may create only the bound namespace and named Run.
pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
    var manifest = committed_review.ReviewRunManifest.parseStrict(
        allocator,
        request.manifest_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .invalid_artifact },
    };
    defer manifest.deinit();
    var findings = committed_review.FindingSet.parseStrict(
        allocator,
        request.findings_bytes,
    ) catch |err| switch (err) {
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

    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        .missing, .unavailable => return .{ .failure = .store_unavailable },
        .failure => |failure| return .{ .failure = mapPublishOpenFailure(failure) },
    };
    defer opened.deinit();
    var initial_directory_name: store_name.RepositoryDirectoryName = undefined;
    if (try publishBindingFailure(
        allocator,
        io,
        opened.root.directory,
        request.locator,
        request.review_repository_id,
        &initial_directory_name,
    )) |failure| return .{ .failure = failure };

    var locks = opened.root.directory.openDirectory(".locks") catch |err| {
        return .{ .failure = if (err == error.FileNotFound)
            .store_invalid
        else
            mapPublishMutationError(err) };
    };
    defer locks.deinit();
    const repository_id_text = request.review_repository_id.canonical();
    var repository_locks = acquireDirectory(io, locks, &repository_id_text, .{}) catch |err| {
        return .{ .failure = mapPublishMutationError(err) };
    };
    defer repository_locks.deinit();
    var lock = acquireLock(io, repository_locks, "publish.lock", .wait) catch |err| {
        return .{ .failure = mapPublishMutationError(err) };
    };
    defer lock.deinit();

    var fresh = switch (context.openExisting()) {
        .opened => |value| value,
        .missing, .unavailable => return .{ .failure = .store_unavailable },
        .failure => |failure| return .{ .failure = mapPublishOpenFailure(failure) },
    };
    defer fresh.deinit();
    if (!fresh.snapshot.eql(opened.snapshot)) return .{ .failure = .concurrent_conflict };
    var repository_directory_name: store_name.RepositoryDirectoryName = undefined;
    if (try publishBindingFailure(
        allocator,
        io,
        fresh.root.directory,
        request.locator,
        request.review_repository_id,
        &repository_directory_name,
    )) |failure| return .{ .failure = failure };
    if (!initial_directory_name.eql(&repository_directory_name)) return .{ .failure = .concurrent_conflict };

    var namespace = fresh.root.directory.openDirectory(repository_directory_name.slice()) catch |err| {
        return .{ .failure = if (err == error.FileNotFound) .store_invalid else mapPublishMutationError(err) };
    };
    defer namespace.deinit();
    if (try existingReviewFailure(allocator, io, namespace, request.review_repository_id, request.review_id)) |failure| {
        return .{ .failure = failure };
    }
    const target_label = if (manifest.value.display) |display|
        if (display.head_label) |saved|
            store_name.TargetLabel.fromSaved(saved) catch
                return .{ .failure = .target_label_invalid }
        else
            store_name.TargetLabel.fromHeadObjectId(&manifest.value.target.head_oid)
    else
        store_name.TargetLabel.fromHeadObjectId(&manifest.value.target.head_oid);
    const unix_seconds = committed_review.strict_json.timestampToUnixSeconds(manifest.value.created_at) catch
        return .{ .failure = .invalid_artifact };
    const local_minute = store_name.LocalCalendarMinute.fromUnixSeconds(unix_seconds) catch
        return .{ .failure = .local_time_unavailable };
    const run_directory_name = store_name.RunDirectoryName.format(
        local_minute,
        &target_label,
        request.review_id,
    );

    return publishReconciledIntoNamespace(
        allocator,
        io,
        namespace,
        request,
        run_directory_name,
        .{},
    );
}

fn publishReconciledIntoNamespace(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    request: PublishRequest,
    run_directory_name: store_name.RunDirectoryName,
    observer: durable.Observer,
) std.mem.Allocator.Error!PublishResult {
    publishIntoNamespace(allocator, io, namespace, request, run_directory_name, observer) catch |err| {
        if (try publishedRequestMatches(
            allocator,
            io,
            namespace,
            request,
            run_directory_name,
        )) return .success;
        if (err == error.LocationConflict) {
            return .{ .failure = (try existingReviewFailure(
                allocator,
                io,
                namespace,
                request.review_repository_id,
                request.review_id,
            )) orelse .concurrent_conflict };
        }
        return .{ .failure = if (err == error.RunNameCollision)
            .run_name_collision
        else if (err == error.ConcurrentStagingConflict)
            .concurrent_conflict
        else
            mapPublishMutationError(err) };
    };
    return .success;
}

fn publishedRequestMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    request: PublishRequest,
    directory_name: store_name.RunDirectoryName,
) std.mem.Allocator.Error!bool {
    var budget: run_store.ArtifactBudget = .{};
    var loaded = try run_store.loadValidated(
        allocator,
        io,
        namespace,
        request.review_repository_id,
        request.review_id,
        &budget,
    );
    defer loaded.deinit(allocator);
    return switch (loaded) {
        .loaded => |*value| value.run_location.location.record.directory_name.eql(&directory_name) and
            std.mem.eql(u8, value.manifest_bytes, request.manifest_bytes) and
            std.mem.eql(u8, value.findings_bytes, request.findings_bytes),
        .invalid => false,
    };
}

pub const DraftRequest = mutation.DraftRequest;
pub const DraftResult = mutation.DraftResult;
pub const ResultRequest = mutation.ResultRequest;
pub const ResultResult = mutation.ResultResult;

pub fn saveDraft(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: DraftRequest,
) std.mem.Allocator.Error!DraftResult {
    const configured = context.configuredPath() orelse return .{ .failure = .io_failed };
    return mutation.saveDraftAt(allocator, io, configured, request);
}

pub fn createResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: ResultRequest,
) std.mem.Allocator.Error!ResultResult {
    const configured = context.configuredPath() orelse return .{ .failure = .io_failed };
    return mutation.createResultAt(allocator, io, configured, request);
}

pub const DeleteRequest = maintenance.DeleteRequest;
pub const DeleteResult = maintenance.DeleteResult;
pub const MaintenanceFailure = maintenance.Failure;
pub const CleanupResult = maintenance.CleanupResult;
pub const deleteRun = maintenance.deleteRun;
pub const cleanupTrash = maintenance.cleanupTrash;

pub const HeldLock = struct {
    file: @FieldType(durable.FileAcquisition, "file"),
    io: std.Io,

    pub fn deinit(self: *HeldLock) void {
        self.file.unlock(self.io);
        self.file.deinit();
        self.* = undefined;
    }
};

pub fn acquireLock(
    io: std.Io,
    directory: capability.DirectoryCapability,
    name: []const u8,
    mode: enum { wait, try_lock },
) !HeldLock {
    const acquired = switch (capability.acquireRegularFile(directory, name, .{})) {
        .not_completed => |err| return err,
        .completed => |result| result,
    };
    var file = acquired.value.file;
    errdefer file.deinit();
    if (acquired.after_error) |err| return err;
    switch (mode) {
        .wait => try file.lock(io, .exclusive),
        .try_lock => if (!try file.tryLock(io, .exclusive)) return error.Locked,
    }
    return .{ .file = file, .io = io };
}

pub fn acquireDirectory(
    io: std.Io,
    parent: capability.DirectoryCapability,
    name: []const u8,
    observer: durable.Observer,
) !capability.DirectoryCapability {
    const acquired = switch (capability.acquireDirectory(io, parent, name, observer)) {
        .not_completed => |err| return err,
        .completed => |result| result,
    };
    if (acquired.value.directory == null) return acquired.after_error orelse error.MetadataUnavailable;
    var directory = acquired.value.directory.?;
    errdefer directory.deinit();
    if (acquired.after_error) |err| return err;
    return directory;
}

const RegistryReplaceOutcome = union(enum) {
    not_committed: anyerror,
    committed: ?anyerror,
};

const RegistryReadback = enum { candidate, previous, ambiguous };

fn atomicReplaceRegistry(
    io: std.Io,
    root: capability.DirectoryCapability,
    bytes: []const u8,
    observer: durable.Observer,
) RegistryReplaceOutcome {
    var name_buffer: [46]u8 = undefined;
    var name: []const u8 = undefined;
    var file_value: ?@FieldType(durable.FileAcquisition, "file") = null;
    var create_after_error: ?anyerror = null;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        io.randomSecure(&token) catch |err| return .{ .not_committed = err };
        name = formatTokenName(&name_buffer, ".tmp-registry-", token) catch |err|
            return .{ .not_committed = err };
        switch (capability.createFile(root, name, observer)) {
            .not_completed => |err| if (err == error.PathAlreadyExists) continue else return .{ .not_committed = err },
            .completed => |result| {
                file_value = result.value;
                create_after_error = result.after_error;
            },
        }
        break;
    }
    var file = file_value orelse return .{ .not_committed = error.ConcurrentStagingConflict };
    defer file.deinit();
    var renamed = false;
    defer if (!renamed) {
        _ = capability.removeFile(io, root, name, .{});
    };
    if (create_after_error) |err| return .{ .not_committed = err };
    switch (durable.writeAll(io, file, bytes, observer)) {
        .not_completed => |err| return .{ .not_committed = err },
        .completed => |result| if (result.after_error) |err| return .{ .not_committed = err },
    }
    switch (durable.syncFile(io, file, observer)) {
        .not_completed => |err| return .{ .not_committed = err },
        .completed => |result| if (result.after_error) |err| return .{ .not_committed = err },
    }
    switch (capability.moveReplacing(io, root, name, root, "registry.json", observer)) {
        .not_completed => |err| return .{ .not_committed = err },
        .completed => |result| {
            renamed = true;
            if (result.after_error) |err| return .{ .committed = err };
        },
    }
    return switch (capability.syncDirectory(io, root, observer)) {
        .not_completed => |err| .{ .committed = err },
        .completed => |result| .{ .committed = result.after_error },
    };
}

fn registryReadback(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: capability.DirectoryCapability,
    candidate: []const u8,
    previous: ?[]const u8,
) std.mem.Allocator.Error!RegistryReadback {
    const bytes = root.readRegularAlloc(allocator, io, "registry.json", registry.max_registry_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound and previous == null) return .previous;
        return .ambiguous;
    };
    defer allocator.free(bytes);
    if (std.mem.eql(u8, bytes, candidate)) return .candidate;
    if (previous) |old| if (std.mem.eql(u8, bytes, old)) return .previous;
    return .ambiguous;
}

fn cleanupOwnedEmptyNamespace(
    io: std.Io,
    root: capability.DirectoryCapability,
    directory_name: []const u8,
    expected: capability.Metadata,
) void {
    var current = root.openDirectory(directory_name) catch return;
    if (!current.metadata.sameObject(expected)) {
        current.deinit();
        return;
    }
    var iterator = current.iterate();
    if ((iterator.next(current, io) catch {
        current.deinit();
        return;
    }) != null) {
        current.deinit();
        return;
    }
    current.deinit();
    switch (capability.removeDirectory(io, root, directory_name, .{})) {
        .not_completed => return,
        .completed => {},
    }
    _ = capability.syncDirectory(io, root, .{});
}

fn existingReviewFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
) std.mem.Allocator.Error!?PublishFailure {
    var budget: run_store.ArtifactBudget = .{};
    const location = try run_store.readLocation(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        &budget,
    );
    switch (location) {
        .absent => return null,
        .invalid => |reason| return publishFailureFromRun(reason),
        .location => {},
    }
    var loaded = try run_store.loadValidated(
        allocator,
        io,
        namespace,
        repository_id,
        review_id,
        &budget,
    );
    defer loaded.deinit(allocator);
    return switch (loaded) {
        .loaded => .duplicate_review_id,
        .invalid => |reason| publishFailureFromRun(reason),
    };
}

fn publishFailureFromRun(reason: run_store.InvalidReason) PublishFailure {
    return switch (reason) {
        .permission_denied => .store_unavailable,
        .io_failed => .io_failed,
        else => .store_invalid,
    };
}

fn publishIntoNamespace(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    request: PublishRequest,
    run_directory_name: store_name.RunDirectoryName,
    observer: durable.Observer,
) !void {
    const location_record: run_store.LocationRecord = .{
        .review_repository_id = request.review_repository_id,
        .review_id = request.review_id,
        .directory_name = run_directory_name,
    };
    const location_bytes = try run_store.writeLocationCanonicalAlloc(allocator, location_record);
    defer allocator.free(location_bytes);

    var temp_name_storage: store_path.NamespaceTempName.Formatted = undefined;
    var staging_token: [16]u8 = undefined;
    var staging_created = false;
    var create_after_error: ?anyerror = null;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        try io.randomSecure(&token);
        const temp_value: store_path.NamespaceTempName = .{
            .kind = .publish,
            .review_id = request.review_id,
            .token = token,
        };
        staging_token = token;
        temp_name_storage = temp_value.format();
        switch (capability.createDirectory(io, namespace, temp_name_storage.slice(), observer)) {
            .not_completed => |err| if (err == error.PathAlreadyExists) continue else return err,
            .completed => |result| {
                staging_created = true;
                create_after_error = result.after_error;
            },
        }
        break;
    }
    if (!staging_created) return error.ConcurrentStagingConflict;
    const temp_name = temp_name_storage.slice();
    var published = false;
    defer if (!published) cleanupStaging(io, namespace, temp_name);
    if (create_after_error) |err| return err;
    var staging = try namespace.openDirectory(temp_name);
    defer staging.deinit();

    try writeExactFile(io, staging, "manifest.json", request.manifest_bytes, observer);
    try writeExactFile(io, staging, "findings.json", request.findings_bytes, observer);
    try completedVoid(capability.syncDirectory(io, staging, observer));
    try completedVoid(capability.syncDirectory(io, namespace, observer));

    const location_temp = (store_path.NamespaceTempName{
        .kind = .location,
        .review_id = request.review_id,
        .token = staging_token,
    }).format();
    const acquired_location = switch (capability.createFile(namespace, location_temp.slice(), observer)) {
        .not_completed => |err| return if (err == error.PathAlreadyExists)
            error.ConcurrentStagingConflict
        else
            err,
        .completed => |result| result,
    };
    var location_file = acquired_location.value;
    defer location_file.deinit();
    var location_temp_present = true;
    defer if (location_temp_present) {
        _ = capability.removeFile(io, namespace, location_temp.slice(), .{});
    };
    if (acquired_location.after_error) |err| return err;
    try completedVoid(durable.writeAll(io, location_file, location_bytes, observer));
    try completedVoid(durable.syncFile(io, location_file, observer));
    try completedVoid(capability.syncDirectory(io, namespace, observer));

    const location_name = store_path.RunLocationName.format(request.review_id);
    switch (capability.movePreserving(
        io,
        namespace,
        location_temp.slice(),
        namespace,
        location_name.slice(),
        observer,
    )) {
        .not_completed => |err| return if (err == error.PathAlreadyExists) error.LocationConflict else err,
        .completed => |result| {
            location_temp_present = false;
            if (result.after_error) |err| {
                if (!cleanupOwnedLocation(
                    allocator,
                    io,
                    namespace,
                    location_name.slice(),
                    location_file.metadata,
                    location_bytes,
                )) return error.ConcurrentStagingConflict;
                return err;
            }
        },
    }
    completedVoid(capability.syncDirectory(io, namespace, observer)) catch |err| {
        if (!cleanupOwnedLocation(
            allocator,
            io,
            namespace,
            location_name.slice(),
            location_file.metadata,
            location_bytes,
        )) return error.ConcurrentStagingConflict;
        return err;
    };

    switch (capability.movePreserving(
        io,
        namespace,
        temp_name,
        namespace,
        run_directory_name.slice(),
        observer,
    )) {
        .not_completed => |err| {
            if (!cleanupOwnedLocation(
                allocator,
                io,
                namespace,
                location_name.slice(),
                location_file.metadata,
                location_bytes,
            )) return error.ConcurrentStagingConflict;
            return if (err == error.PathAlreadyExists) error.RunNameCollision else err;
        },
        .completed => |result| {
            published = true;
            if (result.after_error) |err| return err;
        },
    }
    try completedVoid(capability.syncDirectory(io, namespace, observer));
}

fn cleanupOwnedLocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    name: []const u8,
    expected_metadata: capability.Metadata,
    expected_bytes: []const u8,
) bool {
    const current = namespace.admitChild(name, .regular_file) catch return false;
    if (!current.sameObject(expected_metadata) or current.size != expected_bytes.len) return false;
    const bytes = namespace.readRegularAlloc(allocator, io, name, run_store.max_location_bytes) catch
        return false;
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes, expected_bytes)) return false;
    switch (capability.removeFile(io, namespace, name, .{})) {
        .not_completed => return false,
        .completed => |result| if (result.after_error != null) return false,
    }
    return switch (capability.syncDirectory(io, namespace, .{})) {
        .not_completed => false,
        .completed => |result| result.after_error == null,
    };
}

fn writeExactFile(
    io: std.Io,
    directory: capability.DirectoryCapability,
    name: []const u8,
    bytes: []const u8,
    observer: durable.Observer,
) !void {
    const created = switch (capability.createFile(directory, name, observer)) {
        .not_completed => |err| return err,
        .completed => |result| result,
    };
    var file = created.value;
    defer file.deinit();
    if (created.after_error) |err| return err;
    try completedVoid(durable.writeAll(io, file, bytes, observer));
    try completedVoid(durable.syncFile(io, file, observer));
}

fn cleanupStaging(
    io: std.Io,
    namespace: capability.DirectoryCapability,
    temp_name: []const u8,
) void {
    var staging = namespace.openDirectory(temp_name) catch return;
    defer staging.deinit();
    _ = capability.removeFile(io, staging, "manifest.json", .{});
    _ = capability.removeFile(io, staging, "findings.json", .{});
    switch (capability.removeDirectory(io, namespace, temp_name, .{})) {
        .not_completed => return,
        .completed => {},
    }
    _ = capability.syncDirectory(io, namespace, .{});
}

fn publishBindingFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: capability.DirectoryCapability,
    locator: committed_review.GitCommonDirectoryLocator,
    expected: committed_review.ReviewRepositoryId,
    directory_name: *store_name.RepositoryDirectoryName,
) std.mem.Allocator.Error!?PublishFailure {
    var current = try registry.read(allocator, io, root);
    defer current.deinit();
    return switch (current) {
        .registry => |*parsed| if (parsed.lookup(locator)) |actual| blk: {
            if (!actual.review_repository_id.eql(expected)) break :blk .binding_mismatch;
            const display = store_name.RepositoryDisplayName.fromStored(actual.repository_display_name) catch
                break :blk .store_invalid;
            directory_name.* = store_name.RepositoryDirectoryName.fromStored(
                actual.directory_name,
                &display,
                actual.review_repository_id,
            ) catch break :blk .store_invalid;
            break :blk null;
        } else .binding_mismatch,
        .missing => .binding_mismatch,
        .invalid => .store_invalid,
        .unavailable => .store_unavailable,
    };
}

fn completedVoid(outcome: durable.Outcome(void)) !void {
    switch (outcome) {
        .not_completed => |err| return err,
        .completed => |result| if (result.after_error) |err| return err,
    }
}

fn generateRepositoryId(io: std.Io) !committed_review.ReviewRepositoryId {
    var value: committed_review.ReviewRepositoryId = undefined;
    try io.randomSecure(&value.bytes);
    value.bytes[6] = (value.bytes[6] & 0x0f) | 0x40;
    value.bytes[8] = (value.bytes[8] & 0x3f) | 0x80;
    return value;
}

fn generateReviewId(io: std.Io) !committed_review.ReviewId {
    var value: committed_review.ReviewId = undefined;
    try io.randomSecure(&value.bytes);
    value.bytes[6] = (value.bytes[6] & 0x0f) | 0x40;
    value.bytes[8] = (value.bytes[8] & 0x3f) | 0x80;
    return value;
}

fn bindingLessThan(_: void, left: registry.Binding, right: registry.Binding) bool {
    return left.locator.device < right.locator.device or
        (left.locator.device == right.locator.device and left.locator.inode < right.locator.inode);
}

fn formatTokenName(buffer: []u8, prefix: []const u8, token: [16]u8) ![]const u8 {
    if (buffer.len < prefix.len + token.len * 2) return error.NameTooLong;
    @memcpy(buffer[0..prefix.len], prefix);
    var cursor = prefix.len;
    for (token) |byte| {
        buffer[cursor] = hexLower(byte >> 4);
        buffer[cursor + 1] = hexLower(byte & 0x0f);
        cursor += 2;
    }
    return buffer[0..cursor];
}

fn hexLower(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn mapPrepareOpenError(err: anyerror) PrepareBindingFailure {
    if (err == error.UnsupportedPlatform) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err)) return .store_unavailable;
    if (isUnsafeStoreError(err)) return .store_invalid;
    return .io_failed;
}

fn mapPrepareMutationError(err: anyerror) PrepareBindingFailure {
    if (err == error.UnsupportedPlatform or err == error.OperationUnsupported) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err)) return .store_unavailable;
    if (isUnsafeStoreError(err)) return .store_invalid;
    return .io_failed;
}

fn mapRepositoryNamespaceCreateError(err: anyerror) PrepareBindingFailure {
    return if (err == error.PathAlreadyExists)
        .repository_namespace_collision
    else
        mapPrepareMutationError(err);
}

fn mapPublishOpenFailure(failure: OpenFailure) PublishFailure {
    return switch (failure) {
        .permission_denied, .io_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .unsafe_authority, .invalid => .store_invalid,
    };
}

fn mapPublishMutationError(err: anyerror) PublishFailure {
    if (err == error.UnsupportedPlatform or err == error.OperationUnsupported) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err)) return .store_unavailable;
    if (isUnsafeStoreError(err)) return .store_invalid;
    return .io_failed;
}

fn isUnavailableError(err: anyerror) bool {
    return isPermissionError(err) or isIoUnavailableError(err);
}

fn isPermissionError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "AccessDenied") or
        std.mem.eql(u8, name, "PermissionDenied");
}

fn isIoUnavailableError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "InputOutput") or
        std.mem.eql(u8, name, "ReadOnlyFileSystem") or
        std.mem.eql(u8, name, "NoSpaceLeft") or
        std.mem.eql(u8, name, "DiskQuota");
}

fn isUnsafeStoreError(err: anyerror) bool {
    return switch (err) {
        error.WrongType,
        error.WrongOwner,
        error.WrongMode,
        error.CrossDevice,
        error.MultipleLinks,
        error.SymLinkLoop,
        error.NotDir,
        error.InvalidChildName,
        => true,
        else => false,
    };
}

fn classifyOpenError(err: anyerror) OpenResult {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "FileNotFound")) return .missing;
    if (std.mem.eql(u8, name, "UnsupportedPlatform")) {
        return .{ .failure = .unsupported_platform };
    }
    if (std.mem.eql(u8, name, "UnsupportedFilesystem")) {
        return .{ .failure = .unsupported_filesystem };
    }
    if (isPermissionError(err)) return .{ .failure = .permission_denied };
    if (isIoUnavailableError(err)) return .{ .failure = .io_unavailable };
    if (isUnsafeStoreError(err)) return .{ .failure = .unsafe_authority };
    return .{ .failure = .invalid };
}

test "review store core preserves lossless open taxonomy and publication compatibility" {
    const Case = struct {
        input: anyerror,
        tag: std.meta.Tag(OpenResult),
        open_failure: ?OpenFailure,
        publication_failure: ?PublishFailure,
    };
    const cases = [_]Case{
        .{ .input = error.FileNotFound, .tag = .missing, .open_failure = null, .publication_failure = .store_unavailable },
        .{ .input = error.AccessDenied, .tag = .failure, .open_failure = .permission_denied, .publication_failure = .store_unavailable },
        .{ .input = error.PermissionDenied, .tag = .failure, .open_failure = .permission_denied, .publication_failure = .store_unavailable },
        .{ .input = error.InputOutput, .tag = .failure, .open_failure = .io_unavailable, .publication_failure = .store_unavailable },
        .{ .input = error.ReadOnlyFileSystem, .tag = .failure, .open_failure = .io_unavailable, .publication_failure = .store_unavailable },
        .{ .input = error.NoSpaceLeft, .tag = .failure, .open_failure = .io_unavailable, .publication_failure = .store_unavailable },
        .{ .input = error.DiskQuota, .tag = .failure, .open_failure = .io_unavailable, .publication_failure = .store_unavailable },
        .{ .input = error.WrongType, .tag = .failure, .open_failure = .unsafe_authority, .publication_failure = .store_invalid },
        .{ .input = error.UnsupportedPlatform, .tag = .failure, .open_failure = .unsupported_platform, .publication_failure = .unsupported_platform },
        .{ .input = error.UnsupportedFilesystem, .tag = .failure, .open_failure = .unsupported_filesystem, .publication_failure = .unsupported_filesystem },
        .{ .input = error.NameTooLong, .tag = .failure, .open_failure = .invalid, .publication_failure = .store_invalid },
    };
    for (cases) |case| {
        var classified = classifyOpenError(case.input);
        defer classified.deinit();
        try std.testing.expectEqual(case.tag, std.meta.activeTag(classified));
        const publication_failure: ?PublishFailure = switch (classified) {
            .missing, .unavailable => .store_unavailable,
            .failure => |failure| mapPublishOpenFailure(failure),
            .opened => null,
        };
        try std.testing.expectEqual(case.publication_failure, publication_failure);
        if (case.open_failure) |expected| try std.testing.expectEqual(expected, classified.failure);
    }
}

test "review store core context is configuration-only cloneable and missing-root tolerant" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(parent);
    const missing = try std.fs.path.join(allocator, &.{ parent, "not-created-by-context" });
    defer allocator.free(missing);

    var context = try Context.initConfigured(allocator, missing);
    defer context.deinit(allocator);
    var clone = try context.clone(allocator);
    defer clone.deinit(allocator);
    try std.testing.expectEqualStrings(missing, clone.configuredPath().?);

    var opened = clone.openExisting();
    defer opened.deinit();
    try std.testing.expect(opened == .missing);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "not-created-by-context", .{}));

    const prepared = try prepareBinding(allocator, io, &context, .{
        .locator = .{ .device = 7, .inode = 11 },
        .repository_path = "/physical/repository",
        .repository_name = "repository",
    });
    try std.testing.expect(prepared == .success);
    var visible_later = clone.openExisting();
    defer visible_later.deinit();
    try std.testing.expect(visible_later == .opened);

    var unavailable = try Context.init(allocator, null, null);
    defer unavailable.deinit(allocator);
    try std.testing.expect(unavailable.configuredPath() == null);
    var unavailable_open = unavailable.openExisting();
    defer unavailable_open.deinit();
    try std.testing.expect(unavailable_open == .unavailable);
}

test "review store binding persists the actual repository namespace and never rediscovers its name" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var context = try Context.initConfigured(allocator, store_path_text);
    defer context.deinit(allocator);
    const locator: committed_review.GitCommonDirectoryLocator = .{ .device = 7, .inode = 11 };

    const first_result = try prepareBinding(allocator, io, &context, .{
        .locator = locator,
        .repository_path = "/physical/Main-Repo---",
        .repository_name = "Main-Repo---",
    });
    const first = switch (first_result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expectEqualStrings("Main-Repo", first.repository_display_name.slice());
    const repository_text = first.review_repository_id.canonical();
    var expected_directory_buffer: [255]u8 = undefined;
    const expected_directory = try std.fmt.bufPrint(
        &expected_directory_buffer,
        "Main-Repo-{s}",
        .{repository_text[0..8]},
    );
    try std.testing.expectEqualStrings(expected_directory, first.repository_directory_name.slice());

    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        else => return error.ExpectedStoreRoot,
    };
    defer opened.deinit();
    var namespace = try opened.root.directory.openDirectory(first.repository_directory_name.slice());
    namespace.deinit();
    if (opened.root.directory.openDirectory(&repository_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedUuidNamespace;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const second_result = try prepareBinding(allocator, io, &context, .{
        .locator = locator,
        .repository_path = "/physical/Renamed-Checkout",
        .repository_name = null,
    });
    const second = switch (second_result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expect(first.review_repository_id.eql(second.review_repository_id));
    try std.testing.expect(first.repository_display_name.eql(&second.repository_display_name));
    try std.testing.expect(first.repository_directory_name.eql(&second.repository_directory_name));
    try std.testing.expect(!first.review_id.eql(second.review_id));

    var parsed = try registry.read(allocator, io, opened.root.directory);
    defer parsed.deinit();
    const saved = switch (parsed) {
        .registry => |*value| value.lookup(locator) orelse return error.ExpectedRepositoryBinding,
        else => return error.ExpectedRepositoryBinding,
    };
    try std.testing.expectEqualStrings("Main-Repo", saved.repository_display_name);
    try std.testing.expectEqualStrings(expected_directory, saved.directory_name);
    try std.testing.expectEqualStrings("/physical/Renamed-Checkout", saved.last_seen_path.bytes);

    var raw_store = try tmp.dir.openDir(io, "store", .{});
    defer raw_store.close(io);
    try raw_store.deleteDir(io, expected_directory);
    const missing_namespace = try prepareBinding(allocator, io, &context, .{
        .locator = locator,
        .repository_path = "/physical/Renamed-Again",
        .repository_name = "Must-Not-Replace-Saved-Name",
    });
    try std.testing.expectEqual(PrepareBindingFailure.store_invalid, missing_namespace.failure);

    try std.testing.expectEqual(
        PrepareBindingFailure.repository_namespace_collision,
        mapRepositoryNamespaceCreateError(error.PathAlreadyExists),
    );
}

test "review store repository binding fault edges preserve exactly the proven registry state" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const cases = [_]struct {
        step: durable.Step,
        occurrence: usize = 0,
        committed: bool = false,
    }{
        .{ .step = .{ .operation = .create_directory, .edge = .before } },
        .{ .step = .{ .operation = .create_directory, .edge = .after } },
        .{ .step = .{ .operation = .sync_directory, .edge = .before } },
        .{ .step = .{ .operation = .sync_directory, .edge = .after } },
        .{ .step = .{ .operation = .create_file, .edge = .before } },
        .{ .step = .{ .operation = .create_file, .edge = .after } },
        .{ .step = .{ .operation = .write, .edge = .before } },
        .{ .step = .{ .operation = .write, .edge = .after } },
        .{ .step = .{ .operation = .sync_file, .edge = .before } },
        .{ .step = .{ .operation = .sync_file, .edge = .after } },
        .{ .step = .{ .operation = .rename_replace, .edge = .before } },
        .{ .step = .{ .operation = .rename_replace, .edge = .after }, .committed = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 1, .committed = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 1, .committed = true },
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "store", .fromMode(0o700));
        const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
        defer allocator.free(store_path_text);
        var context = try Context.initConfigured(allocator, store_path_text);
        defer context.deinit(allocator);
        var fault: TestStepObserver = .{ .selected = case.step, .occurrence = case.occurrence };
        const result = try prepareBindingWithObserver(allocator, io, &context, .{
            .locator = .{ .device = 7, .inode = 11 },
            .repository_path = "/physical/repository",
            .repository_name = "repository",
        }, fault.observer());
        try std.testing.expectEqual(PrepareBindingFailure.io_failed, result.failure);
        try std.testing.expect(fault.seen > case.occurrence);

        var opened = switch (context.openExisting()) {
            .opened => |value| value,
            else => return error.ExpectedStoreRoot,
        };
        defer opened.deinit();
        var current = try registry.read(allocator, io, opened.root.directory);
        defer current.deinit();
        switch (current) {
            .missing => try std.testing.expect(!case.committed),
            .registry => |*parsed| {
                try std.testing.expect(case.committed);
                try std.testing.expectEqual(@as(usize, 1), parsed.bindings.len);
                var actual = try opened.root.directory.openDirectory(parsed.bindings[0].directory_name);
                actual.deinit();
            },
            else => return error.UnexpectedRegistryState,
        }
        var iterator = opened.root.directory.iterate();
        var namespace_count: usize = 0;
        while (try iterator.next(opened.root.directory, io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".tmp-registry-"));
            if (std.mem.eql(u8, entry.name, ".locks") or std.mem.eql(u8, entry.name, "registry.json")) continue;
            namespace_count += 1;
        }
        try std.testing.expectEqual(@as(usize, @intFromBool(case.committed)), namespace_count);
    }
}

test "review store repository binding never deletes nonempty or ambiguous namespace residue" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]BindingResidueMode{ .nonempty, .ambiguous_registry }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "store", .fromMode(0o700));
        const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
        defer allocator.free(store_path_text);
        var raw_store = try tmp.dir.openDir(io, "store", .{ .iterate = true });
        defer raw_store.close(io);
        var context = try Context.initConfigured(allocator, store_path_text);
        defer context.deinit(allocator);
        var fault: BindingResidueFault = .{ .io = io, .store = raw_store, .mode = mode };
        const result = try prepareBindingWithObserver(allocator, io, &context, .{
            .locator = .{ .device = 7, .inode = 11 },
            .repository_path = "/physical/repository",
            .repository_name = "repository",
        }, fault.observer());
        try std.testing.expect(result == .failure);
        try std.testing.expect(fault.fired);

        var iterator = raw_store.iterate();
        var namespace_name: ?[255]u8 = null;
        var namespace_len: usize = 0;
        while (try iterator.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".locks") or
                std.mem.eql(u8, entry.name, "registry.json") or
                std.mem.startsWith(u8, entry.name, ".tmp-registry-")) continue;
            if (namespace_name != null) return error.UnexpectedNamespaceCount;
            var copied: [255]u8 = undefined;
            @memcpy(copied[0..entry.name.len], entry.name);
            namespace_name = copied;
            namespace_len = entry.name.len;
        }
        try std.testing.expect(namespace_name != null);
        var namespace = try raw_store.openDir(io, namespace_name.?[0..namespace_len], .{});
        defer namespace.close(io);
        if (mode == .nonempty) {
            var foreign = try namespace.openFile(io, "foreign", .{});
            foreign.close(io);
        } else {
            const bytes = try raw_store.readFileAlloc(io, "registry.json", allocator, .limited(64));
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings("{ambiguous\n", bytes);
        }
    }
}

test "review run publication fault boundaries expose all-or-nothing final directories and clean only own staging" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var root = try capability.StoreRootCapability.openCanonical(store_path_text);
    defer root.deinit();
    const repository_id = try committed_review.ReviewRepositoryId.parse(
        "123e4567-e89b-42d3-a456-426614174000",
    );
    var namespace = try acquireDirectory(io, root.directory, "repository-123e4567", .{});
    defer namespace.deinit();

    const cases = [_]PublicationFaultCase{
        .{ .step = .{ .operation = .create_directory, .edge = .after } },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_file, .edge = .before }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_file, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_file, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_file, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_file, .edge = .before }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_file, .edge = .after }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 3 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 3 },
        .{ .step = .{ .operation = .rename_preserve, .edge = .before }, .occurrence = 0 },
        .{ .step = .{ .operation = .rename_preserve, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .rename_preserve, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .rename_preserve, .edge = .after }, .occurrence = 1, .published = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 4, .published = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 4, .published = true },
    };
    for (cases, 0..) |case, index| {
        var id_bytes = [_]u8{0} ** 16;
        id_bytes[0] = @intCast(index + 1);
        id_bytes[6] = 0x40;
        id_bytes[8] = 0x80;
        const review_id: committed_review.ReviewId = .{ .bytes = id_bytes };
        const request: PublishRequest = .{
            .locator = .{ .device = 0, .inode = 0 },
            .review_repository_id = repository_id,
            .review_id = review_id,
            .manifest_bytes = "manifest-exact\n",
            .findings_bytes = "findings-exact\x00\n",
        };
        const review_id_text = review_id.canonical();
        var directory_storage: [255]u8 = undefined;
        const directory_text = try std.fmt.bufPrint(
            &directory_storage,
            "20260913-1000-test-{s}",
            .{review_id_text[0..8]},
        );
        const run_directory_name = try store_name.RunDirectoryName.fromStored(directory_text, review_id);
        var fault: TestStepObserver = .{ .selected = case.step, .occurrence = case.occurrence };
        try std.testing.expectError(
            error.InjectedPublicationFault,
            publishIntoNamespace(allocator, io, namespace, request, run_directory_name, fault.observer()),
        );
        if (namespace.openDirectory(run_directory_name.slice())) |final| {
            var owned = final;
            defer owned.deinit();
            try std.testing.expect(case.published);
            const manifest = try owned.readRegularAlloc(allocator, io, "manifest.json", 64);
            defer allocator.free(manifest);
            const findings = try owned.readRegularAlloc(allocator, io, "findings.json", 64);
            defer allocator.free(findings);
            try std.testing.expectEqualSlices(u8, request.manifest_bytes, manifest);
            try std.testing.expectEqualSlices(u8, request.findings_bytes, findings);
        } else |err| {
            try std.testing.expect(!case.published);
            try std.testing.expectEqual(error.FileNotFound, err);
        }
        const location_name = store_path.RunLocationName.format(review_id);
        if (namespace.admitChild(location_name.slice(), .regular_file)) |_| {
            try std.testing.expect(case.published);
        } else |err| {
            try std.testing.expect(!case.published);
            try std.testing.expectEqual(error.FileNotFound, err);
        }
    }

    var iterator = namespace.iterate();
    var canonical_count: usize = 0;
    while (try iterator.next(namespace, io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".tmp-publish-") and
            !std.mem.startsWith(u8, entry.name, ".tmp-location-"));
        canonical_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), canonical_count);

    var boundary_namespace = try acquireDirectory(io, root.directory, "boundary-123e4567", .{});
    defer boundary_namespace.deinit();
    var raw_store = try tmp.dir.openDir(io, "store", .{});
    defer raw_store.close(io);
    var raw_boundary = try raw_store.openDir(io, "boundary-123e4567", .{});
    defer raw_boundary.close(io);
    for (0..512) |index| {
        const review_id = testReviewId(index);
        var artifacts = try TestPublishArtifacts.init(allocator, repository_id, review_id);
        defer artifacts.deinit(allocator);
        const run_directory_name = testRunDirectoryName(review_id);
        try raw_boundary.createDir(io, run_directory_name.slice(), .fromMode(0o700));
        var raw_run = try raw_boundary.openDir(io, run_directory_name.slice(), .{});
        defer raw_run.close(io);
        try raw_run.writeFile(io, .{
            .sub_path = "manifest.json",
            .data = artifacts.manifest,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        try raw_run.writeFile(io, .{
            .sub_path = "findings.json",
            .data = artifacts.findings,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        const location_bytes = try run_store.writeLocationCanonicalAlloc(allocator, .{
            .review_repository_id = repository_id,
            .review_id = review_id,
            .directory_name = run_directory_name,
        });
        defer allocator.free(location_bytes);
        const location_name = store_path.RunLocationName.format(review_id);
        try raw_boundary.writeFile(io, .{
            .sub_path = location_name.slice(),
            .data = location_bytes,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }

    const boundary_review_id = testReviewId(512);
    var boundary_artifacts = try TestPublishArtifacts.init(allocator, repository_id, boundary_review_id);
    defer boundary_artifacts.deinit(allocator);
    const boundary_request: PublishRequest = .{
        .locator = .{ .device = 0, .inode = 0 },
        .review_repository_id = repository_id,
        .review_id = boundary_review_id,
        .manifest_bytes = boundary_artifacts.manifest,
        .findings_bytes = boundary_artifacts.findings,
    };
    const boundary_run_name = testRunDirectoryName(boundary_review_id);
    var post_publish_fault: TestStepObserver = .{
        .selected = .{ .operation = .rename_preserve, .edge = .after },
        .occurrence = 1,
    };
    try std.testing.expectEqual(
        PublishResult.success,
        try publishReconciledIntoNamespace(
            allocator,
            io,
            boundary_namespace,
            boundary_request,
            boundary_run_name,
            post_publish_fault.observer(),
        ),
    );
    var budget: run_store.ArtifactBudget = .{};
    var loaded = try run_store.loadValidated(
        allocator,
        io,
        boundary_namespace,
        repository_id,
        boundary_review_id,
        &budget,
    );
    defer loaded.deinit(allocator);
    switch (loaded) {
        .loaded => |*value| try std.testing.expect(value.run_location.location.record.directory_name.eql(
            &boundary_run_name,
        )),
        .invalid => return error.ExpectedPublishedBoundaryRun,
    }
}

const PublicationFaultCase = struct {
    step: durable.Step,
    occurrence: usize = 0,
    published: bool = false,
};

const TestPublishArtifacts = struct {
    manifest: []u8,
    findings: []u8,

    fn init(
        allocator: std.mem.Allocator,
        repository_id: committed_review.ReviewRepositoryId,
        review_id: committed_review.ReviewId,
    ) !TestPublishArtifacts {
        const oid = try committed_review.ObjectId.parse(
            .sha1,
            "0123456789abcdef0123456789abcdef01234567",
        );
        const target: committed_review.CommittedReviewTarget = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        };
        const findings_value: committed_review.FindingSet = .{
            .schema_version = 1,
            .review_id = review_id,
            .created_at = "2026-09-13T10:00:00Z",
            .target = target,
            .producer = .{ .name = "test" },
            .findings = &.{},
        };
        const findings = try findings_value.writeCanonical(allocator);
        errdefer allocator.free(findings);
        const manifest_value: committed_review.ReviewRunManifest = .{
            .schema_version = 1,
            .review_id = review_id,
            .review_repository_id = repository_id,
            .target = target,
            .created_at = findings_value.created_at,
            .display = .{ .head_label = "test" },
            .finding_count = 0,
            .producer = findings_value.producer,
            .findings_digest = committed_review.Sha256Digest.hash(findings),
        };
        return .{
            .manifest = try manifest_value.writeCanonical(allocator),
            .findings = findings,
        };
    }

    fn deinit(self: *TestPublishArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest);
        allocator.free(self.findings);
        self.* = undefined;
    }
};

fn testReviewId(index: usize) committed_review.ReviewId {
    var bytes = [_]u8{0} ** 16;
    bytes[0] = @intCast((index >> 8) & 0xff);
    bytes[1] = @intCast(index & 0xff);
    bytes[6] = 0x40;
    bytes[8] = 0x80;
    return .{ .bytes = bytes };
}

fn testRunDirectoryName(review_id: committed_review.ReviewId) store_name.RunDirectoryName {
    const label = store_name.TargetLabel.fromStored("test") catch unreachable;
    return .format(.{ .year = 2026, .month = 9, .day = 13, .hour = 10, .minute = 0 }, &label, review_id);
}

const TestStepObserver = struct {
    selected: durable.Step,
    occurrence: usize,
    seen: usize = 0,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.selected.operation != step.operation or self.selected.edge != step.edge) return;
        defer self.seen += 1;
        if (self.seen == self.occurrence) return error.InjectedPublicationFault;
    }

    fn observer(self: *@This()) durable.Observer {
        return .{ .context = self, .observe_fn = observe };
    }
};

const BindingResidueMode = enum { nonempty, ambiguous_registry };

const BindingResidueFault = struct {
    io: std.Io,
    store: std.Io.Dir,
    mode: BindingResidueMode,
    fired: bool = false,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.fired or step.operation != .rename_replace or step.edge != .before) return;
        self.fired = true;
        switch (self.mode) {
            .nonempty => {
                var iterator = self.store.iterate();
                while (try iterator.next(self.io)) |entry| {
                    if (std.mem.eql(u8, entry.name, ".locks") or
                        std.mem.eql(u8, entry.name, "registry.json") or
                        std.mem.startsWith(u8, entry.name, ".tmp-registry-")) continue;
                    var namespace = try self.store.openDir(self.io, entry.name, .{});
                    defer namespace.close(self.io);
                    try namespace.writeFile(self.io, .{
                        .sub_path = "foreign",
                        .data = "keep\n",
                        .flags = .{ .permissions = .fromMode(0o600) },
                    });
                    break;
                }
            },
            .ambiguous_registry => try self.store.writeFile(self.io, .{
                .sub_path = "registry.json",
                .data = "{ambiguous\n",
                .flags = .{ .permissions = .fromMode(0o600) },
            }),
        }
        return error.InjectedPublicationFault;
    }

    fn observer(self: *@This()) durable.Observer {
        return .{ .context = self, .observe_fn = observe };
    }
};
