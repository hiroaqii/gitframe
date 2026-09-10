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
const registry = @import("registry.zig");
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
    io_failed,
    concurrent_conflict,
};

pub const PrepareBindingRequest = struct {
    locator: committed_review.GitCommonDirectoryLocator,
    repository_path: []const u8,
};

pub const PrepareBindingSuccess = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
};

pub const PrepareBindingResult = union(enum) {
    success: PrepareBindingSuccess,
    failure: PrepareBindingFailure,
};

/// The only Store core operation allowed to create the configured root and
/// reconcile registry authority. It creates no repository namespace or Run.
pub fn prepareBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const Context,
    request: PrepareBindingRequest,
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
    var replacement_needed = false;
    var bindings_owner: ?[]registry.Binding = null;
    defer if (bindings_owner) |owned| allocator.free(owned);
    var bindings: []registry.Binding = undefined;
    if (existing) |parsed| {
        bindings = try allocator.alloc(
            registry.Binding,
            parsed.bindings.len + @intFromBool(parsed.lookup(request.locator) == null),
        );
        bindings_owner = bindings;
        @memcpy(bindings[0..parsed.bindings.len], parsed.bindings);
        if (parsed.lookup(request.locator)) |found| {
            repository_id = found;
            for (bindings[0..parsed.bindings.len]) |*binding| {
                if (!binding.locator.eql(request.locator)) continue;
                if (!std.mem.eql(u8, binding.last_seen_path.bytes, request.repository_path)) {
                    binding.last_seen_path = diagnostic_path;
                    replacement_needed = true;
                }
                break;
            }
        } else {
            repository_id = generateRepositoryId(io) catch return .{ .failure = .io_failed };
            bindings[bindings.len - 1] = .{
                .review_repository_id = repository_id,
                .locator = request.locator,
                .canonical_path = diagnostic_path,
                .last_seen_path = diagnostic_path,
            };
            std.mem.sort(registry.Binding, bindings, {}, bindingLessThan);
            replacement_needed = true;
        }
    } else {
        repository_id = generateRepositoryId(io) catch return .{ .failure = .io_failed };
        bindings = try allocator.alloc(registry.Binding, 1);
        bindings_owner = bindings;
        bindings[0] = .{
            .review_repository_id = repository_id,
            .locator = request.locator,
            .canonical_path = diagnostic_path,
            .last_seen_path = diagnostic_path,
        };
        replacement_needed = true;
    }

    if (replacement_needed) {
        const bytes = registry.writeCanonicalAlloc(allocator, bindings) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = .store_invalid },
        };
        defer allocator.free(bytes);
        atomicReplaceRegistry(io, root.directory, bytes) catch |err| {
            return .{ .failure = if (err == error.ConcurrentStagingConflict)
                .concurrent_conflict
            else
                mapPrepareMutationError(err) };
        };
    }

    const review_id = generateReviewId(io) catch return .{ .failure = .io_failed };
    return .{ .success = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
    } };
}

pub const PublishFailure = enum {
    invalid_artifact,
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
    if (try publishBindingFailure(
        allocator,
        io,
        opened.root.directory,
        request.locator,
        request.review_repository_id,
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
    if (try publishBindingFailure(
        allocator,
        io,
        fresh.root.directory,
        request.locator,
        request.review_repository_id,
    )) |failure| return .{ .failure = failure };

    var namespace = acquireDirectory(io, fresh.root.directory, &repository_id_text, .{}) catch |err| {
        return .{ .failure = mapPublishMutationError(err) };
    };
    defer namespace.deinit();
    const review_id_text = request.review_id.canonical();
    if (namespace.openDirectory(&review_id_text)) |existing_run| {
        var owned = existing_run;
        owned.deinit();
        return .{ .failure = .duplicate_review_id };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return .{ .failure = .store_invalid },
    }

    publishIntoNamespace(io, namespace, request, .{}) catch |err| {
        return .{ .failure = if (err == error.DuplicateReviewId)
            .duplicate_review_id
        else if (err == error.ConcurrentStagingConflict)
            .concurrent_conflict
        else
            mapPublishMutationError(err) };
    };
    return .success;
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

fn atomicReplaceRegistry(
    io: std.Io,
    root: capability.DirectoryCapability,
    bytes: []const u8,
) !void {
    var name_buffer: [46]u8 = undefined;
    var name: []const u8 = undefined;
    var file_value: ?@FieldType(durable.FileAcquisition, "file") = null;
    var create_after_error: ?anyerror = null;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        try io.randomSecure(&token);
        name = try formatTokenName(&name_buffer, ".tmp-registry-", token);
        switch (capability.createFile(root, name, .{})) {
            .not_completed => |err| if (err == error.PathAlreadyExists) continue else return err,
            .completed => |result| {
                file_value = result.value;
                create_after_error = result.after_error;
            },
        }
        break;
    }
    var file = file_value orelse return error.ConcurrentStagingConflict;
    defer file.deinit();
    var renamed = false;
    defer if (!renamed) {
        _ = capability.removeFile(io, root, name, .{});
    };
    if (create_after_error) |err| return err;
    try completedVoid(durable.writeAll(io, file, bytes, .{}));
    try completedVoid(durable.syncFile(io, file, .{}));
    switch (capability.moveReplacing(io, root, name, root, "registry.json", .{})) {
        .not_completed => |err| return err,
        .completed => |result| {
            renamed = true;
            if (result.after_error) |err| return err;
        },
    }
    try completedVoid(capability.syncDirectory(io, root, .{}));
}

fn publishIntoNamespace(
    io: std.Io,
    namespace: capability.DirectoryCapability,
    request: PublishRequest,
    observer: durable.Observer,
) !void {
    var temp_name_storage: store_path.NamespaceTempName.Formatted = undefined;
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
    const review_id_text = request.review_id.canonical();
    switch (capability.movePreserving(io, namespace, temp_name, namespace, &review_id_text, observer)) {
        .not_completed => |err| return if (err == error.PathAlreadyExists) error.DuplicateReviewId else err,
        .completed => |result| {
            published = true;
            if (result.after_error) |err| return err;
        },
    }
    try completedVoid(capability.syncDirectory(io, namespace, observer));
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
) std.mem.Allocator.Error!?PublishFailure {
    var current = try registry.read(allocator, io, root);
    defer current.deinit();
    return switch (current) {
        .registry => |*parsed| if (parsed.lookup(locator)) |actual|
            if (actual.eql(expected)) null else .binding_mismatch
        else
            .binding_mismatch,
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
    const repository_id_text = repository_id.canonical();
    var namespace = try acquireDirectory(io, root.directory, &repository_id_text, .{});
    defer namespace.deinit();

    const cases = [_]PublicationFaultCase{
        .{ .step = .{ .operation = .create_directory, .edge = .after } },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_file, .edge = .before }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_file, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_file, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_file, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 0 },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .rename_preserve, .edge = .before } },
        .{ .step = .{ .operation = .rename_preserve, .edge = .after }, .published = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 2, .published = true },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 2, .published = true },
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
        var fault: TestStepObserver = .{ .selected = case.step, .occurrence = case.occurrence };
        try std.testing.expectError(
            error.InjectedPublicationFault,
            publishIntoNamespace(io, namespace, request, fault.observer()),
        );
        const review_id_text = review_id.canonical();
        if (namespace.openDirectory(&review_id_text)) |final| {
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
    }

    var iterator = namespace.iterate();
    var canonical_count: usize = 0;
    while (try iterator.next(namespace, io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".tmp-publish-"));
        canonical_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), canonical_count);
}

const PublicationFaultCase = struct {
    step: durable.Step,
    occurrence: usize = 0,
    published: bool = false,
};

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
