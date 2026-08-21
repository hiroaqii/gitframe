//! Explicit Review Store binding preparation and immutable Run publication.
//!
//! This is the only Issue #105 owner allowed to create registry authority or
//! expose producer-owned manifest/findings bytes. Read callers never import it
//! as a fallback mutation path.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const config = @import("../config.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const repository_locator = @import("../git/repository_locator.zig");
const root_capability = @import("../repo/root_capability.zig");
const capability = @import("capability.zig");
const registry = @import("registry.zig");
const run_artifacts = @import("run.zig");
const store_path = @import("path.zig");

pub const Failure = enum {
    invalid_artifact,
    target_unavailable,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    duplicate_review_id,
    store_invalid,
    repository_invalid,
    git_failed,
    io_failed,
    binding_mismatch,
    concurrent_conflict,
};

pub const PrepareSuccess = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
};

pub const PrepareResult = union(enum) {
    success: PrepareSuccess,
    failure: Failure,
};

pub const PublishRequest = struct {
    repository_path: []const u8,
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    manifest_bytes: []const u8,
    findings_bytes: []const u8,
};

pub const PublishResult = union(enum) {
    success,
    failure: Failure,
};

const RepositoryContext = struct {
    root: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,
    locator: committed_review.GitCommonDirectoryLocator,

    fn deinit(self: *RepositoryContext) void {
        self.environment.deinit();
        self.root.deinit();
        self.* = undefined;
    }

    fn git(self: *const RepositoryContext) git_command.DirectoryContext {
        return .{ .cwd = self.root.dir(), .environment = &self.environment };
    }
};

const RepositoryOpenResult = union(enum) {
    context: RepositoryContext,
    failure: Failure,
};

const ResolvedStore = union(enum) {
    path: []u8,
    failure: Failure,

    fn deinit(self: *ResolvedStore, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .path => |value| allocator.free(value),
            .failure => {},
        }
        self.* = .{ .failure = .store_unavailable };
    }
};

const HeldLock = struct {
    file: std.Io.File,
    io: std.Io,

    fn deinit(self: *HeldLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

const PublicationFaultPoint = enum {
    before_manifest_sync,
    after_manifest_sync,
    before_findings_sync,
    after_findings_sync,
    before_staging_directory_sync,
    after_staging_directory_sync,
    before_staging_namespace_sync,
    after_staging_namespace_sync,
    before_rename,
    after_rename,
    before_final_namespace_sync,
    after_final_namespace_sync,
};

const PublicationFaults = struct {
    context: ?*anyopaque = null,
    check_fn: *const fn (?*anyopaque, PublicationFaultPoint) anyerror!void = noFault,

    fn check(self: PublicationFaults, point: PublicationFaultPoint) !void {
        try self.check_fn(self.context, point);
    }

    fn noFault(_: ?*anyopaque, _: PublicationFaultPoint) !void {}
};

/// Resolve one physical repository and durably get-or-create its machine-local
/// binding. This is the only operation that may create the Store root or
/// registry, and it creates no repository namespace or Run directory.
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

    var resolved = try resolveStoreRoot(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const resolved_path = switch (resolved) {
        .path => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };

    var root = capability.StoreRootCapability.openOrCreateCanonical(io, resolved_path) catch |err| {
        return .{ .failure = mapStoreCreateError(err) };
    };
    defer root.deinit();
    var locks = root.directory.getOrCreateDirectory(io, ".locks") catch |err| {
        return .{ .failure = mapStoreMutationError(err) };
    };
    defer locks.deinit();
    var lock = acquireLock(io, locks, "registry.lock") catch |err| {
        return .{ .failure = mapStoreMutationError(err) };
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

    const diagnostic_path = registry.diagnosticPath(repository_path) catch
        return .{ .failure = .repository_invalid };
    var repository_id: committed_review.ReviewRepositoryId = undefined;
    var replacement_needed = false;
    var bindings_owner: ?[]registry.Binding = null;
    defer if (bindings_owner) |owned| allocator.free(owned);
    var bindings: []registry.Binding = undefined;
    if (existing) |parsed| {
        bindings = try allocator.alloc(registry.Binding, parsed.bindings.len +
            @intFromBool(parsed.lookup(repository.locator) == null));
        bindings_owner = bindings;
        @memcpy(bindings[0..parsed.bindings.len], parsed.bindings);
        if (parsed.lookup(repository.locator)) |found| {
            repository_id = found;
            for (bindings[0..parsed.bindings.len]) |*binding| {
                if (!binding.locator.eql(repository.locator)) continue;
                if (!std.mem.eql(u8, binding.last_seen_path.bytes, repository_path)) {
                    binding.last_seen_path = diagnostic_path;
                    replacement_needed = true;
                }
                break;
            }
        } else {
            repository_id = generateRepositoryId(io) catch
                return .{ .failure = .io_failed };
            bindings[bindings.len - 1] = .{
                .review_repository_id = repository_id,
                .locator = repository.locator,
                .canonical_path = diagnostic_path,
                .last_seen_path = diagnostic_path,
            };
            std.mem.sort(registry.Binding, bindings, {}, bindingLessThan);
            replacement_needed = true;
        }
    } else {
        repository_id = generateRepositoryId(io) catch
            return .{ .failure = .io_failed };
        bindings = try allocator.alloc(registry.Binding, 1);
        bindings_owner = bindings;
        bindings[0] = .{
            .review_repository_id = repository_id,
            .locator = repository.locator,
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
                mapStoreMutationError(err) };
        };
    }

    const review_id = generateReviewId(io) catch return .{ .failure = .io_failed };
    return .{ .success = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
    } };
}

/// Validate exact caller bytes and current Git/Store authority before exposing
/// one immutable no-replace Run directory.
pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
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

    var repository = switch (try openRepository(allocator, io, environment_map, request.repository_path)) {
        .context => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer repository.deinit();
    const availability = try git_review.checkTargetAvailability(
        allocator,
        io,
        repository.git(),
        manifest.value.target,
    );
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => |failure| return .{ .failure = switch (failure) {
            .invalid_repository => .repository_invalid,
            .invalid_target => .invalid_artifact,
            else => .git_failed,
        } },
    }

    var resolved = try resolveStoreRoot(allocator, io, environment_map);
    defer resolved.deinit(allocator);
    const resolved_path = switch (resolved) {
        .path => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    var root = capability.StoreRootCapability.openCanonical(resolved_path) catch |err| {
        return .{ .failure = mapStoreOpenError(err) };
    };
    defer root.deinit();
    if (try bindingFailure(
        allocator,
        io,
        root.directory,
        repository.locator,
        request.review_repository_id,
    )) |failure| return .{ .failure = failure };

    var locks = root.directory.openDirectory(".locks") catch |err| {
        return .{ .failure = if (err == error.FileNotFound)
            .store_invalid
        else
            mapStoreOpenError(err) };
    };
    defer locks.deinit();
    const repository_id_text = request.review_repository_id.canonical();
    var repository_locks = locks.getOrCreateDirectory(io, &repository_id_text) catch |err| {
        return .{ .failure = mapStoreMutationError(err) };
    };
    defer repository_locks.deinit();
    var lock = acquireLock(io, repository_locks, "publish.lock") catch |err| {
        return .{ .failure = mapStoreMutationError(err) };
    };
    defer lock.deinit();

    var fresh_root = capability.StoreRootCapability.openCanonical(resolved_path) catch |err| {
        return .{ .failure = mapStoreOpenError(err) };
    };
    defer fresh_root.deinit();
    if (!fresh_root.directory.metadata.sameObject(root.directory.metadata)) {
        return .{ .failure = .concurrent_conflict };
    }
    if (try bindingFailure(
        allocator,
        io,
        fresh_root.directory,
        repository.locator,
        request.review_repository_id,
    )) |failure| return .{ .failure = failure };

    var namespace = fresh_root.directory.getOrCreateDirectory(io, &repository_id_text) catch |err| {
        return .{ .failure = mapStoreMutationError(err) };
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

    return publishIntoNamespace(io, namespace, request, .{}) catch |err| {
        return .{ .failure = mapPublishError(err) };
    };
}

fn openRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
) std.mem.Allocator.Error!RepositoryOpenResult {
    var root = root_capability.RootCapability.openCanonical(repository_path) catch |err| {
        return .{ .failure = if (err == error.UnsupportedPlatform)
            .unsupported_platform
        else
            .repository_invalid };
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

fn resolveStoreRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
) std.mem.Allocator.Error!ResolvedStore {
    var paths = try config.resolvePaths(allocator, environment_map);
    defer paths.deinit(allocator);
    var loaded = config.loadConfig(allocator, io, paths.config);
    defer loaded.deinit();
    const configured = switch (loaded) {
        .success => |*owned| owned.value.ai_review.store_root,
        .failure => return .{ .failure = .store_invalid },
    };
    const resolved = store_path.resolveFromEnvironment(allocator, configured, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .store_invalid },
    };
    return switch (resolved) {
        .available => |value| .{ .path = value },
        .unavailable => .{ .failure = .store_unavailable },
    };
}

fn acquireLock(
    io: std.Io,
    directory: capability.DirectoryCapability,
    name: []const u8,
) !HeldLock {
    const file = try directory.openOrCreateRegularFile(name);
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    return .{ .file = file, .io = io };
}

fn bindingFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: capability.DirectoryCapability,
    locator: committed_review.GitCommonDirectoryLocator,
    expected: committed_review.ReviewRepositoryId,
) std.mem.Allocator.Error!?Failure {
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

fn atomicReplaceRegistry(
    io: std.Io,
    root: capability.DirectoryCapability,
    bytes: []const u8,
) !void {
    var name_buffer: [46]u8 = undefined;
    var name: []const u8 = undefined;
    var file_value: ?std.Io.File = null;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        try io.randomSecure(&token);
        name = try formatTokenName(&name_buffer, ".tmp-registry-", token);
        file_value = root.createRegularFileExclusive(name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    const file = file_value orelse return error.ConcurrentStagingConflict;
    defer file.close(io);
    var renamed = false;
    defer if (!renamed) root.dir().deleteFile(io, name) catch {};
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try root.dir().rename(name, root.dir(), "registry.json", io);
    renamed = true;
    try root.sync(io);
}

fn publishIntoNamespace(
    io: std.Io,
    namespace: capability.DirectoryCapability,
    request: PublishRequest,
    faults: PublicationFaults,
) !PublishResult {
    var temp_name_storage: store_path.NamespaceTempName.Formatted = undefined;
    var staging_created = false;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        try io.randomSecure(&token);
        const temp_value: store_path.NamespaceTempName = .{
            .kind = .publish,
            .review_id = request.review_id,
            .token = token,
        };
        temp_name_storage = temp_value.format();
        namespace.dir().createDir(io, temp_name_storage.slice(), .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        staging_created = true;
        break;
    }
    if (!staging_created) return error.ConcurrentStagingConflict;
    const temp_name = temp_name_storage.slice();
    var published = false;
    defer if (!published) cleanupStaging(io, namespace, temp_name);
    var staging = try namespace.openDirectory(temp_name);
    defer staging.deinit();

    try writeExactFile(
        io,
        staging,
        "manifest.json",
        request.manifest_bytes,
        faults,
        .before_manifest_sync,
        .after_manifest_sync,
    );
    try writeExactFile(
        io,
        staging,
        "findings.json",
        request.findings_bytes,
        faults,
        .before_findings_sync,
        .after_findings_sync,
    );
    try faults.check(.before_staging_directory_sync);
    try staging.sync(io);
    try faults.check(.after_staging_directory_sync);
    try faults.check(.before_staging_namespace_sync);
    try namespace.sync(io);
    try faults.check(.after_staging_namespace_sync);
    const review_id_text = request.review_id.canonical();
    try faults.check(.before_rename);
    namespace.dir().renamePreserve(temp_name, namespace.dir(), &review_id_text, io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DuplicateReviewId,
        else => return err,
    };
    published = true;
    try faults.check(.after_rename);
    try faults.check(.before_final_namespace_sync);
    try namespace.sync(io);
    try faults.check(.after_final_namespace_sync);
    return .success;
}

fn writeExactFile(
    io: std.Io,
    directory: capability.DirectoryCapability,
    name: []const u8,
    bytes: []const u8,
    faults: PublicationFaults,
    before_sync: PublicationFaultPoint,
    after_sync: PublicationFaultPoint,
) !void {
    const file = try directory.createRegularFileExclusive(name);
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try faults.check(before_sync);
    try file.sync(io);
    try faults.check(after_sync);
}

fn cleanupStaging(
    io: std.Io,
    namespace: capability.DirectoryCapability,
    temp_name: []const u8,
) void {
    var staging = namespace.openDirectory(temp_name) catch return;
    defer staging.deinit();
    staging.dir().deleteFile(io, "manifest.json") catch {};
    staging.dir().deleteFile(io, "findings.json") catch {};
    namespace.dir().deleteDir(io, temp_name) catch return;
    namespace.sync(io) catch {};
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

fn mapStoreCreateError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err)) return .store_unavailable;
    if (isUnsafeStoreError(err)) return .store_invalid;
    return .io_failed;
}

fn mapStoreOpenError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err) or err == error.FileNotFound) return .store_unavailable;
    return .store_invalid;
}

fn mapStoreMutationError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform or err == error.OperationUnsupported) return .unsupported_platform;
    if (err == error.UnsupportedFilesystem) return .unsupported_filesystem;
    if (isUnavailableError(err)) return .store_unavailable;
    if (isUnsafeStoreError(err)) return .store_invalid;
    return .io_failed;
}

fn mapPublishError(err: anyerror) Failure {
    if (err == error.DuplicateReviewId) return .duplicate_review_id;
    if (err == error.ConcurrentStagingConflict) return .concurrent_conflict;
    return mapStoreMutationError(err);
}

fn isUnavailableError(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "AccessDenied") or
        std.mem.eql(u8, name, "PermissionDenied") or
        std.mem.eql(u8, name, "InputOutput") or
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

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn testGitLine(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0 and result.stdout.len > 1 and
            result.stdout[result.stdout.len - 1] == '\n' and
            std.mem.indexOfScalar(u8, result.stdout[0 .. result.stdout.len - 1], '\n') == null)
        {
            return result.stdout;
        },
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    return error.GitCommandFailed;
}

const ConcurrentPrepare = struct {
    io: std.Io,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    result: PrepareResult = .{ .failure = .io_failed },
    failed: bool = false,

    fn execute(self: *@This()) void {
        self.result = prepare(
            std.heap.smp_allocator,
            self.io,
            self.environment,
            self.repository_path,
        ) catch {
            self.failed = true;
            return;
        };
    }
};

const ConcurrentPublish = struct {
    io: std.Io,
    environment: *std.process.Environ.Map,
    request_value: PublishRequest,
    result: PublishResult = .{ .failure = .io_failed },
    failed: bool = false,

    fn execute(self: *@This()) void {
        self.result = publish(
            std.heap.smp_allocator,
            self.io,
            self.environment,
            self.request_value,
        ) catch {
            self.failed = true;
            return;
        };
    }
};

const TestPublicationFault = struct {
    selected: PublicationFaultPoint,

    fn check(context: ?*anyopaque, point: PublicationFaultPoint) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.selected == point) return error.InjectedPublicationFault;
    }

    fn interface(self: *@This()) PublicationFaults {
        return .{ .context = self, .check_fn = check };
    }
};

test "review run publication prepare creates one durable binding and no Run namespace" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "base",
    });
    try tmp.dir.createDir(io, "state", .fromMode(0o700));
    const repository_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repository_path);
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", allocator);
    defer allocator.free(state_path);
    const config_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", state_path);
    try environment.put("XDG_CONFIG_HOME", config_path);

    var concurrent = [_]ConcurrentPrepare{
        .{ .io = io, .environment = &environment, .repository_path = repository_path },
        .{ .io = io, .environment = &environment, .repository_path = repository_path },
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentPrepare.execute, .{&concurrent[0]});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentPrepare.execute, .{&concurrent[1]});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!concurrent[0].failed and !concurrent[1].failed);
    const first_success = switch (concurrent[0].result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const concurrent_success = switch (concurrent[1].result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expect(first_success.review_repository_id.eql(concurrent_success.review_repository_id));
    try std.testing.expect(!first_success.review_id.eql(concurrent_success.review_id));
    const later = try prepare(allocator, io, &environment, repository_path);
    const second_success = switch (later) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expect(first_success.review_repository_id.eql(second_success.review_repository_id));
    try std.testing.expect(!first_success.review_id.eql(second_success.review_id));

    const store_root = try std.fs.path.join(allocator, &.{ state_path, "gitframe", "ai-reviews" });
    defer allocator.free(store_root);
    var root = try capability.StoreRootCapability.openCanonical(store_root);
    defer root.deinit();
    var parsed = try registry.read(allocator, io, root.directory);
    defer parsed.deinit();
    const value = switch (parsed) {
        .registry => |*owned| owned,
        else => return error.ExpectedRegistry,
    };
    try std.testing.expectEqual(@as(usize, 1), value.bindings.len);
    try std.testing.expect(value.bindings[0].review_repository_id.eql(first_success.review_repository_id));
    try std.testing.expectEqualSlices(u8, repository_path, value.bindings[0].canonical_path.bytes);
    const repository_id_text = first_success.review_repository_id.canonical();
    if (root.directory.openDirectory(&repository_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedRunNamespace;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const invalid_registry = "{invalid-registry\n";
    try root.directory.dir().writeFile(io, .{
        .sub_path = "registry.json",
        .data = invalid_registry,
    });
    const invalid_prepare = try prepare(allocator, io, &environment, repository_path);
    try std.testing.expect(invalid_prepare == .failure);
    try std.testing.expectEqual(Failure.store_invalid, invalid_prepare.failure);
    const preserved_invalid = try root.directory.readRegularAlloc(
        allocator,
        io,
        "registry.json",
        registry.max_registry_bytes,
    );
    defer allocator.free(preserved_invalid);
    try std.testing.expectEqualSlices(u8, invalid_registry, preserved_invalid);
}

test "review run publication preserves exact bytes rejects duplicates and reopens through the reader" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "base",
    });
    const base_output = try testGitLine(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_output);
    try repo.writeFile(io, .{ .sub_path = "file", .data = "head\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "head",
    });
    const head_output = try testGitLine(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_output);
    const base_text = base_output[0 .. base_output.len - 1];
    const head_text = head_output[0 .. head_output.len - 1];
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
        .head_oid = try committed_review.ObjectId.parse(.sha1, head_text),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
    };

    try tmp.dir.createDir(io, "state", .fromMode(0o700));
    const repository_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repository_path);
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", allocator);
    defer allocator.free(state_path);
    const config_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", state_path);
    try environment.put("XDG_CONFIG_HOME", config_path);
    const prepared = try prepare(allocator, io, &environment, repository_path);
    const identities = switch (prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };

    const producer: committed_review.Producer = .{ .name = "publication-test", .model = "fixture" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .created_at = "2026-08-21T03:00:00Z",
        .timing = .{ .duration_ms = 7 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .review_repository_id = identities.review_repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = .{ .base_label = "base", .head_label = "head" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    const request: PublishRequest = .{
        .repository_path = repository_path,
        .review_repository_id = identities.review_repository_id,
        .review_id = identities.review_id,
        .manifest_bytes = manifest_bytes,
        .findings_bytes = findings_bytes,
    };
    var concurrent = [_]ConcurrentPublish{
        .{ .io = io, .environment = &environment, .request_value = request },
        .{ .io = io, .environment = &environment, .request_value = request },
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentPublish.execute, .{&concurrent[0]});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentPublish.execute, .{&concurrent[1]});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!concurrent[0].failed and !concurrent[1].failed);
    const successes = @intFromBool(concurrent[0].result == .success) +
        @intFromBool(concurrent[1].result == .success);
    try std.testing.expectEqual(@as(usize, 1), successes);
    const conflict = if (concurrent[0].result == .failure)
        concurrent[0].result.failure
    else
        concurrent[1].result.failure;
    try std.testing.expectEqual(Failure.duplicate_review_id, conflict);
    const alternate_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .created_at = "2026-08-21T03:00:01Z",
        .target = target,
        .producer = .{ .name = "different-publication", .model = null },
        .findings = &.{},
    };
    const alternate_findings_bytes = try alternate_findings.writeCanonical(allocator);
    defer allocator.free(alternate_findings_bytes);
    const alternate_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .review_repository_id = identities.review_repository_id,
        .target = target,
        .created_at = alternate_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = alternate_findings.producer,
        .findings_digest = committed_review.Sha256Digest.hash(alternate_findings_bytes),
    };
    const alternate_manifest_bytes = try alternate_manifest.writeCanonical(allocator);
    defer allocator.free(alternate_manifest_bytes);
    const duplicate = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = identities.review_repository_id,
        .review_id = identities.review_id,
        .manifest_bytes = alternate_manifest_bytes,
        .findings_bytes = alternate_findings_bytes,
    });
    try std.testing.expect(duplicate == .failure);
    try std.testing.expectEqual(Failure.duplicate_review_id, duplicate.failure);

    const store_root = try std.fs.path.join(allocator, &.{ state_path, "gitframe", "ai-reviews" });
    defer allocator.free(store_root);
    var root = try capability.StoreRootCapability.openCanonical(store_root);
    defer root.deinit();
    const repository_id_text = identities.review_repository_id.canonical();
    var namespace = try root.directory.openDirectory(&repository_id_text);
    defer namespace.deinit();
    const review_id_text = identities.review_id.canonical();
    var run_dir = try namespace.openDirectory(&review_id_text);
    defer run_dir.deinit();
    const stored_manifest = try run_dir.readRegularAlloc(
        allocator,
        io,
        "manifest.json",
        committed_review.limits.max_manifest_bytes,
    );
    defer allocator.free(stored_manifest);
    const stored_findings = try run_dir.readRegularAlloc(
        allocator,
        io,
        "findings.json",
        committed_review.limits.max_artifact_bytes,
    );
    defer allocator.free(stored_findings);
    try std.testing.expectEqualSlices(u8, manifest_bytes, stored_manifest);
    try std.testing.expectEqualSlices(u8, findings_bytes, stored_findings);

    var budget: run_artifacts.ArtifactBudget = .{};
    var loaded = try run_artifacts.loadValidated(
        allocator,
        io,
        namespace,
        identities.review_repository_id,
        identities.review_id,
        &budget,
    );
    defer loaded.deinit(allocator);
    try std.testing.expect(loaded == .loaded);
    try std.testing.expectEqualSlices(u8, manifest_bytes, loaded.loaded.manifest_bytes);
    try std.testing.expectEqualSlices(u8, findings_bytes, loaded.loaded.findings_bytes);

    const next_prepared = try prepare(allocator, io, &environment, repository_path);
    const next = switch (next_prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const mismatched_artifact = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = next.review_repository_id,
        .review_id = next.review_id,
        .manifest_bytes = manifest_bytes,
        .findings_bytes = findings_bytes,
    });
    try std.testing.expect(mismatched_artifact == .failure);
    try std.testing.expectEqual(Failure.invalid_artifact, mismatched_artifact.failure);
    const next_id_text = next.review_id.canonical();
    if (namespace.openDirectory(&next_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedInvalidArtifactRun;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const wrong_repository_id = try committed_review.ReviewRepositoryId.parse(
        "123e4567-e89b-42d3-b456-426614174000",
    );
    const next_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = next.review_id,
        .created_at = "2026-08-21T03:01:00Z",
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const next_findings_bytes = try next_findings.writeCanonical(allocator);
    defer allocator.free(next_findings_bytes);
    const wrong_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = next.review_id,
        .review_repository_id = wrong_repository_id,
        .target = target,
        .created_at = next_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(next_findings_bytes),
    };
    const wrong_manifest_bytes = try wrong_manifest.writeCanonical(allocator);
    defer allocator.free(wrong_manifest_bytes);
    const wrong_binding = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = wrong_repository_id,
        .review_id = next.review_id,
        .manifest_bytes = wrong_manifest_bytes,
        .findings_bytes = next_findings_bytes,
    });
    try std.testing.expect(wrong_binding == .failure);
    try std.testing.expectEqual(Failure.binding_mismatch, wrong_binding.failure);
    const wrong_repository_text = wrong_repository_id.canonical();
    if (root.directory.openDirectory(&wrong_repository_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedMismatchedBindingNamespace;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const missing_prepared = try prepare(allocator, io, &environment, repository_path);
    const missing = switch (missing_prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const zero_oid = "0000000000000000000000000000000000000000";
    const unavailable_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
        .head_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
    };
    const missing_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = missing.review_id,
        .created_at = "2026-08-21T03:02:00Z",
        .target = unavailable_target,
        .producer = producer,
        .findings = &.{},
    };
    const missing_findings_bytes = try missing_findings.writeCanonical(allocator);
    defer allocator.free(missing_findings_bytes);
    const missing_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = missing.review_id,
        .review_repository_id = missing.review_repository_id,
        .target = unavailable_target,
        .created_at = missing_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(missing_findings_bytes),
    };
    const missing_manifest_bytes = try missing_manifest.writeCanonical(allocator);
    defer allocator.free(missing_manifest_bytes);
    const unavailable = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = missing.review_repository_id,
        .review_id = missing.review_id,
        .manifest_bytes = missing_manifest_bytes,
        .findings_bytes = missing_findings_bytes,
    });
    try std.testing.expect(unavailable == .failure);
    try std.testing.expectEqual(Failure.target_unavailable, unavailable.failure);
    const missing_id_text = missing.review_id.canonical();
    if (namespace.openDirectory(&missing_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedUnavailableTargetRun;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
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
    var namespace = try root.directory.getOrCreateDirectory(io, &repository_id_text);
    defer namespace.deinit();

    const points = [_]PublicationFaultPoint{
        .before_manifest_sync,
        .after_manifest_sync,
        .before_findings_sync,
        .after_findings_sync,
        .before_staging_directory_sync,
        .after_staging_directory_sync,
        .before_staging_namespace_sync,
        .after_staging_namespace_sync,
        .before_rename,
        .after_rename,
        .before_final_namespace_sync,
        .after_final_namespace_sync,
    };
    for (points, 0..) |point, index| {
        var id_bytes = [_]u8{0} ** 16;
        id_bytes[0] = @intCast(index + 1);
        id_bytes[6] = 0x40;
        id_bytes[8] = 0x80;
        const review_id: committed_review.ReviewId = .{ .bytes = id_bytes };
        const request: PublishRequest = .{
            .repository_path = "/unused",
            .review_repository_id = repository_id,
            .review_id = review_id,
            .manifest_bytes = "manifest-exact\n",
            .findings_bytes = "findings-exact\x00\n",
        };
        var fault: TestPublicationFault = .{ .selected = point };
        try std.testing.expectError(
            error.InjectedPublicationFault,
            publishIntoNamespace(io, namespace, request, fault.interface()),
        );
        const review_id_text = review_id.canonical();
        const renamed = point == .after_rename or
            point == .before_final_namespace_sync or
            point == .after_final_namespace_sync;
        if (namespace.openDirectory(&review_id_text)) |final| {
            var owned = final;
            defer owned.deinit();
            try std.testing.expect(renamed);
            const manifest = try owned.readRegularAlloc(allocator, io, "manifest.json", 64);
            defer allocator.free(manifest);
            const findings = try owned.readRegularAlloc(allocator, io, "findings.json", 64);
            defer allocator.free(findings);
            try std.testing.expectEqualSlices(u8, request.manifest_bytes, manifest);
            try std.testing.expectEqualSlices(u8, request.findings_bytes, findings);
        } else |err| {
            try std.testing.expect(!renamed);
            try std.testing.expectEqual(error.FileNotFound, err);
        }
    }

    var iterator = namespace.dir().iterate();
    var canonical_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".tmp-publish-"));
        canonical_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), canonical_count);
}
