//! Exact Run deletion and explicit cleanup of this operation's private residue.
//! Lock order: repository publication, then Run. No writer lock file is removed.
const std = @import("std");
const review = @import("../committed_review.zig");
const durable = @import("../fs/durable.zig");
const capability = @import("capability.zig");
const core = @import("core.zig");
const catalog = @import("catalog.zig");
const registry = @import("registry.zig");
const run = @import("run.zig");
const store_path = @import("path.zig");

pub const Failure = enum {
    not_found,
    conflict,
    unfinished,
    binding_changed,
    run_invalid,
    permission_denied,
    io_failed,
    store_unavailable,
    unsupported,
};

pub const DeleteRequest = struct {
    store: catalog.StoreSnapshot,
    review_id: review.ReviewId,
    artifacts: run.ArtifactSnapshot,
    allow_unfinished: bool = false,
};

pub const Cleanup = union(enum) { complete, pending: Failure };
pub const DeleteResult = union(enum) { deleted: Cleanup, failure: Failure };
pub const CleanupResult = union(enum) {
    cleaned: usize,
    stopped: struct { cleaned: usize, failed: usize = 1, unprocessed: usize, name: TrashName, failure: Failure },
    failure: Failure,
};

const artifact_names = [_][]const u8{ "manifest.json", "findings.json", "review_state.json", "result.json" };
const TrashName = [69]u8;
const LocationTrashName = [74]u8;
const max_trash_entries = 512;

pub fn deleteRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    request: DeleteRequest,
) std.mem.Allocator.Error!DeleteResult {
    return deleteWith(allocator, io, context, request, .{});
}

fn deleteWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    request: DeleteRequest,
    observer: durable.Observer,
) std.mem.Allocator.Error!DeleteResult {
    const cleanup = deleteLocked(allocator, io, context, request, observer) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = classify(err) };
    };
    return .{ .deleted = cleanup };
}

fn deleteLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    request: DeleteRequest,
    observer: durable.Observer,
) !Cleanup {
    const repository_name = request.store.review_repository_id.canonical();
    const review_name = request.review_id.canonical();
    _ = review.ReviewId.parse(&review_name) catch return error.InvalidRun;
    var opened = try openExpected(context, request.store);
    defer opened.deinit();
    try validateBinding(allocator, io, opened.root.directory, request.store);
    var namespace = try opened.root.directory.openDirectory(request.store.repository_directory_name.slice());
    defer namespace.deinit();
    const current_location = switch (try run.readLocation(
        allocator,
        io,
        namespace,
        request.store.review_repository_id,
        request.review_id,
        null,
    )) {
        .location => |value| value,
        .absent => return error.FileNotFound,
        .invalid => return error.InvalidRun,
    };
    const expected_location = request.artifacts.run_location orelse return error.InvalidRun;
    if (!expected_location.location.record.review_repository_id.eql(request.store.review_repository_id) or
        !expected_location.location.record.review_id.eql(request.review_id)) return error.Conflict;
    if (!current_location.eql(expected_location.location)) return error.Conflict;
    const actual_name = current_location.record.directory_name.slice();
    var selected = try namespace.openDirectory(actual_name);
    defer selected.deinit();

    var locks = opened.root.directory.openDirectory(".locks") catch |err| return missingLock(err);
    defer locks.deinit();
    var repository_locks = locks.openDirectory(&repository_name) catch |err| return missingLock(err);
    defer repository_locks.deinit();
    var publish_lock = try core.acquireLock(io, repository_locks, "publish.lock", .try_lock);
    defer publish_lock.deinit();
    var lock_name: [41]u8 = undefined;
    _ = try std.fmt.bufPrint(&lock_name, "{s}.lock", .{review_name});
    var run_lock = try core.acquireLock(io, repository_locks, &lock_name, .try_lock);
    defer run_lock.deinit();

    try validateLocation(allocator, io, context, request.store, namespace, selected, expected_location);
    try validateFiles(io, selected);
    var budget: run.ArtifactBudget = .{};
    var loaded = try run.loadValidated(allocator, io, namespace, request.store.review_repository_id, request.review_id, &budget);
    defer loaded.deinit(allocator);
    const artifacts = switch (loaded) {
        .loaded => |*value| value,
        .invalid => |reason| return switch (reason) {
            .permission_denied => error.AccessDenied,
            .io_failed => error.InputOutput,
            else => error.InvalidRun,
        },
    };
    if (artifacts.retained_draft_diagnostic != null and artifacts.draft_bytes == null) return error.InvalidRun;
    if (!run.ArtifactSnapshot.fromLoaded(artifacts).eql(request.artifacts)) return error.Conflict;
    if (artifacts.result == null and !request.allow_unfinished) return error.Unfinished;

    var trash = try core.acquireDirectory(io, opened.root.directory, ".trash", observer);
    defer trash.deinit();
    var repository_trash = try core.acquireDirectory(io, trash, &repository_name, observer);
    defer repository_trash.deinit();
    try completed(capability.syncDirectory(io, repository_trash, observer));
    try completed(capability.syncDirectory(io, trash, observer));
    try completed(capability.syncDirectory(io, opened.root.directory, observer));
    var nonce: [16]u8 = undefined;
    std.Io.random(io, &nonce);
    const nonce_text = std.fmt.bytesToHex(nonce, .lower);
    var name: TrashName = undefined;
    _ = try std.fmt.bufPrint(&name, "{s}-{s}", .{ review_name, nonce_text });
    var location_trash_name: LocationTrashName = undefined;
    _ = try std.fmt.bufPrint(&location_trash_name, ".run-{s}-{s}", .{ review_name, nonce_text });

    try validateLocation(allocator, io, context, request.store, namespace, selected, expected_location);
    // From completed rename onward, failures can only describe cleanup pending.
    try validateTrash(opened.root.directory, trash, repository_trash, &repository_name);
    const moved = switch (capability.movePreserving(io, namespace, actual_name, repository_trash, &name, observer)) {
        .not_completed => |err| return if (err == error.FileNotFound) error.Conflict else err,
        .completed => |value| value,
    };
    completed(capability.syncDirectory(io, namespace, observer)) catch |err| return .{ .pending = classify(err) };
    completed(capability.syncDirectory(io, repository_trash, observer)) catch |err| return .{ .pending = classify(err) };
    if (moved.after_error) |err| return .{ .pending = classify(err) };
    validateMovedRun(
        allocator,
        io,
        namespace,
        repository_trash,
        selected,
        expected_location,
        &name,
    ) catch |err| return .{ .pending = classify(err) };
    const location_name = store_path.RunLocationName.format(request.review_id);
    const location_moved = switch (capability.movePreserving(
        io,
        namespace,
        location_name.slice(),
        repository_trash,
        &location_trash_name,
        observer,
    )) {
        .not_completed => |err| return .{ .pending = classify(if (err == error.FileNotFound) error.Conflict else err) },
        .completed => |value| value,
    };
    completed(capability.syncDirectory(io, namespace, observer)) catch |err| return .{ .pending = classify(err) };
    completed(capability.syncDirectory(io, repository_trash, observer)) catch |err| return .{ .pending = classify(err) };
    if (location_moved.after_error) |err| return .{ .pending = classify(err) };
    removeResidue(io, repository_trash, &name, observer) catch |err| return .{ .pending = classify(err) };
    removeLocationResidue(
        allocator,
        io,
        repository_trash,
        &location_trash_name,
        expected_location.location,
        observer,
    ) catch |err| return .{ .pending = classify(err) };
    return .complete;
}

/// No automatic caller. Only the currently bound repository's private trash.
pub fn cleanupTrash(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    expected: catalog.StoreSnapshot,
) std.mem.Allocator.Error!CleanupResult {
    return cleanupWith(allocator, io, context, expected, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = classify(err) };
    };
}

fn cleanupWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    expected: catalog.StoreSnapshot,
    observer: durable.Observer,
) !CleanupResult {
    var opened = try openExpected(context, expected);
    defer opened.deinit();
    try validateBinding(allocator, io, opened.root.directory, expected);
    const repository_name = expected.review_repository_id.canonical();
    var locks = opened.root.directory.openDirectory(".locks") catch |err| return missingLock(err);
    defer locks.deinit();
    var repository_locks = locks.openDirectory(&repository_name) catch |err| return missingLock(err);
    defer repository_locks.deinit();
    var lock = try core.acquireLock(io, repository_locks, "publish.lock", .try_lock);
    defer lock.deinit();
    var fresh = try openExpected(context, expected);
    defer fresh.deinit();
    try validateBinding(allocator, io, fresh.root.directory, expected);
    var trash = fresh.root.directory.openDirectory(".trash") catch |err| {
        if (err == error.FileNotFound) return .{ .cleaned = 0 };
        return err;
    };
    defer trash.deinit();
    var repository_trash = trash.openDirectory(&repository_name) catch |err| {
        if (err == error.FileNotFound) return .{ .cleaned = 0 };
        return err;
    };
    defer repository_trash.deinit();
    var namespace = try fresh.root.directory.openDirectory(expected.repository_directory_name.slice());
    defer namespace.deinit();

    // Inventory before mutation: fixed grammars bound both count and name bytes.
    // A location entry is admitted only with its same-token Run residue.
    var names: [max_trash_entries]TrashName = undefined;
    var location_names: [max_trash_entries]LocationTrashName = undefined;
    var count: usize = 0;
    var location_count: usize = 0;
    var iterator = repository_trash.iterate();
    while (try iterator.next(repository_trash, io)) |entry| {
        if (validTrashName(entry.name)) {
            if (count == names.len) return error.InvalidRun;
            _ = repository_trash.admitChild(entry.name, .directory) catch return error.InvalidRun;
            @memcpy(&names[count], entry.name);
            count += 1;
        } else if (validLocationTrashName(entry.name)) {
            if (location_count == location_names.len) return error.InvalidRun;
            _ = repository_trash.admitChild(entry.name, .regular_file) catch return error.InvalidRun;
            @memcpy(&location_names[location_count], entry.name);
            location_count += 1;
        } else {
            return error.InvalidRun;
        }
    }
    try completed(capability.syncDirectory(io, namespace, observer));
    try completed(capability.syncDirectory(io, repository_trash, observer));
    var cleaned: usize = 0;
    const orphan_locations = countOrphanLocations(names[0..count], location_names[0..location_count]);
    const total = count + orphan_locations;
    for (names[0..count]) |*name| {
        cleanupTrashRun(
            allocator,
            io,
            namespace,
            repository_trash,
            expected.review_repository_id,
            name,
            observer,
        ) catch |err| return .{ .stopped = .{
            .cleaned = cleaned,
            .unprocessed = total - cleaned - 1,
            .name = name.*,
            .failure = classify(err),
        } };
        cleaned += 1;
    }
    for (location_names[0..location_count]) |*location_name| {
        if (containsTrashRun(names[0..count], location_name[5..])) continue;
        var run_name: TrashName = undefined;
        @memcpy(&run_name, location_name[5..]);
        cleanupLocationOnly(
            allocator,
            io,
            namespace,
            repository_trash,
            expected.review_repository_id,
            location_name,
            observer,
        ) catch |err| return .{ .stopped = .{
            .cleaned = cleaned,
            .unprocessed = total - cleaned - 1,
            .name = run_name,
            .failure = classify(err),
        } };
        cleaned += 1;
    }
    return .{ .cleaned = cleaned };
}

fn validTrashName(name: []const u8) bool {
    if (name.len != 69 or name[36] != '-') return false;
    _ = review.ReviewId.parse(name[0..36]) catch return false;
    for (name[37..]) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validLocationTrashName(name: []const u8) bool {
    return name.len == @sizeOf(LocationTrashName) and
        std.mem.startsWith(u8, name, ".run-") and
        validTrashName(name[5..]);
}

fn containsTrashRun(names: []const TrashName, wanted: []const u8) bool {
    for (names) |*name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

fn countOrphanLocations(names: []const TrashName, location_names: []const LocationTrashName) usize {
    var count: usize = 0;
    for (location_names) |*location_name| {
        if (!containsTrashRun(names, location_name[5..])) count += 1;
    }
    return count;
}

fn validateFiles(io: std.Io, directory: capability.DirectoryCapability) !void {
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(directory, io)) |entry| {
        if (count == artifact_names.len) return error.InvalidRun;
        var known = false;
        for (artifact_names) |name| if (std.mem.eql(u8, name, entry.name)) {
            known = true;
            break;
        };
        if (!known) return error.InvalidRun;
        _ = directory.admitChild(entry.name, .regular_file) catch |err| return if (err == error.FileNotFound) error.Conflict else err;
        count += 1;
    }
}

fn validateMovedRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_trash: capability.DirectoryCapability,
    selected: capability.DirectoryCapability,
    expected: run.RunLocationSnapshot,
    trash_name: []const u8,
) !void {
    const moved = try repository_trash.admitChild(trash_name, .directory);
    if (!moved.sameObject(selected.metadata)) return error.Conflict;
    _ = namespace.admitChild(expected.location.record.directory_name.slice(), .directory) catch |err| {
        if (err != error.FileNotFound) return err;
        const current_location = switch (try run.readLocation(
            allocator,
            io,
            namespace,
            expected.location.record.review_repository_id,
            expected.location.record.review_id,
            null,
        )) {
            .location => |value| value,
            .absent, .invalid => return error.Conflict,
        };
        if (!current_location.eql(expected.location)) return error.Conflict;
        return;
    };
    return error.Conflict;
}

fn cleanupTrashRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_trash: capability.DirectoryCapability,
    repository_id: review.ReviewRepositoryId,
    trash_name: *const TrashName,
    observer: durable.Observer,
) !void {
    const review_id = review.ReviewId.parse(trash_name[0..36]) catch return error.InvalidRun;
    var directory = try repository_trash.openDirectory(trash_name);
    defer directory.deinit();
    try validateFiles(io, directory);

    var location_trash_name: LocationTrashName = undefined;
    _ = try std.fmt.bufPrint(&location_trash_name, ".run-{s}", .{trash_name.*});
    const expected_location = blk: {
        if (repository_trash.admitChild(&location_trash_name, .regular_file)) |_| {
            break :blk try readLocationResidue(
                allocator,
                io,
                repository_trash,
                &location_trash_name,
                repository_id,
                review_id,
            );
        } else |err| if (err != error.FileNotFound) return err;
        const manifest_bytes = try directory.readRegularAlloc(
            allocator,
            io,
            "manifest.json",
            review.limits.max_manifest_bytes,
        );
        defer allocator.free(manifest_bytes);
        var manifest = review.ReviewRunManifest.parseStrict(allocator, manifest_bytes) catch |parse_err| {
            if (parse_err == error.OutOfMemory) return parse_err;
            return error.InvalidRun;
        };
        defer manifest.deinit();
        if (!manifest.value.review_repository_id.eql(repository_id) or
            !manifest.value.review_id.eql(review_id)) return error.InvalidRun;
        const canonical = switch (try run.readLocation(
            allocator,
            io,
            namespace,
            repository_id,
            review_id,
            null,
        )) {
            .location => |value| value,
            .absent => return error.InvalidRun,
            .invalid => return error.InvalidRun,
        };
        try requireActualRunAbsent(namespace, canonical.record.directory_name.slice());
        const location_name = store_path.RunLocationName.format(review_id);
        const moved = switch (capability.movePreserving(
            io,
            namespace,
            location_name.slice(),
            repository_trash,
            &location_trash_name,
            observer,
        )) {
            .not_completed => |move_err| return move_err,
            .completed => |value| value,
        };
        try completed(capability.syncDirectory(io, namespace, observer));
        try completed(capability.syncDirectory(io, repository_trash, observer));
        if (moved.after_error) |move_err| return move_err;
        break :blk canonical;
    };
    try requireActualRunAbsent(namespace, expected_location.record.directory_name.slice());
    try removeResidue(io, repository_trash, trash_name, observer);
    try removeLocationResidue(
        allocator,
        io,
        repository_trash,
        &location_trash_name,
        expected_location,
        observer,
    );
}

fn cleanupLocationOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_trash: capability.DirectoryCapability,
    repository_id: review.ReviewRepositoryId,
    location_name: *const LocationTrashName,
    observer: durable.Observer,
) !void {
    const review_id = review.ReviewId.parse(location_name[5..41]) catch return error.InvalidRun;
    const location = try readLocationResidue(
        allocator,
        io,
        repository_trash,
        location_name,
        repository_id,
        review_id,
    );
    try requireActualRunAbsent(namespace, location.record.directory_name.slice());
    try removeLocationResidue(allocator, io, repository_trash, location_name, location, observer);
}

fn readLocationResidue(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: capability.DirectoryCapability,
    name: []const u8,
    repository_id: review.ReviewRepositoryId,
    review_id: review.ReviewId,
) !run.LocationSnapshot {
    const metadata = try parent.admitChild(name, .regular_file);
    const bytes = try parent.readRegularAlloc(allocator, io, name, run.max_location_bytes);
    defer allocator.free(bytes);
    if (bytes.len != metadata.size) return error.InvalidRun;
    const record = run.parseLocationStrict(allocator, bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidRun;
    };
    if (!record.review_repository_id.eql(repository_id) or !record.review_id.eql(review_id)) {
        return error.InvalidRun;
    }
    return .{
        .record = record,
        .metadata = metadata,
        .digest = review.Sha256Digest.hash(bytes),
    };
}

fn removeLocationResidue(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: capability.DirectoryCapability,
    name: []const u8,
    expected: run.LocationSnapshot,
    observer: durable.Observer,
) !void {
    const current = try readLocationResidue(
        allocator,
        io,
        parent,
        name,
        expected.record.review_repository_id,
        expected.record.review_id,
    );
    if (!current.eql(expected)) return error.Conflict;
    try completed(capability.removeFile(io, parent, name, observer));
    try completed(capability.syncDirectory(io, parent, observer));
}

fn requireActualRunAbsent(namespace: capability.DirectoryCapability, actual_name: []const u8) !void {
    _ = namespace.admitChild(actual_name, .directory) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    return error.Conflict;
}

fn removeResidue(io: std.Io, parent: capability.DirectoryCapability, name: []const u8, observer: durable.Observer) !void {
    var directory = try parent.openDirectory(name);
    defer directory.deinit();
    try validateFiles(io, directory);
    for (artifact_names) |artifact| {
        _ = directory.admitChild(artifact, .regular_file) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        try completed(capability.removeFile(io, directory, artifact, observer));
    }
    try completed(capability.syncDirectory(io, directory, observer));
    const current = try parent.admitChild(name, .directory);
    if (!current.sameObject(directory.metadata)) return error.Conflict;
    try completed(capability.removeDirectory(io, parent, name, observer));
    try completed(capability.syncDirectory(io, parent, observer));
}

fn openExpected(context: *const core.Context, expected: catalog.StoreSnapshot) !core.OpenedRoot {
    _ = review.ReviewRepositoryId.parse(&expected.review_repository_id.canonical()) catch return error.InvalidRun;
    var opened = switch (context.openExisting()) {
        .opened => |value| value,
        .missing => return error.FileNotFound,
        .unavailable => return error.StoreUnavailable,
        .failure => |failure| return switch (failure) {
            .permission_denied => error.AccessDenied,
            .io_unavailable => error.InputOutput,
            .unsupported_platform, .unsupported_filesystem => error.UnsupportedPlatform,
            .unsafe_authority, .invalid => error.InvalidRun,
        },
    };
    errdefer opened.deinit();
    if (!opened.snapshot.eql(expected.root())) return error.BindingChanged;
    return opened;
}

fn validateBinding(allocator: std.mem.Allocator, io: std.Io, root: capability.DirectoryCapability, expected: catalog.StoreSnapshot) !void {
    const bytes = root.readRegularAlloc(allocator, io, "registry.json", registry.max_registry_bytes) catch |err| {
        return if (err == error.FileNotFound) error.BindingChanged else err;
    };
    defer allocator.free(bytes);
    var parsed = registry.parseStrict(allocator, bytes) catch |err| {
        return if (err == error.OutOfMemory) err else error.InvalidRun;
    };
    defer parsed.deinit();
    const found = parsed.lookup(expected.repository_locator) orelse return error.BindingChanged;
    if (!found.review_repository_id.eql(expected.review_repository_id) or
        !std.mem.eql(u8, found.repository_display_name, expected.repository_display_name.slice()) or
        !std.mem.eql(u8, found.directory_name, expected.repository_directory_name.slice()))
    {
        return error.BindingChanged;
    }
}

fn validateLocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *const core.Context,
    expected: catalog.StoreSnapshot,
    namespace: capability.DirectoryCapability,
    selected: capability.DirectoryCapability,
    location: run.RunLocationSnapshot,
) !void {
    var fresh = try openExpected(context, expected);
    defer fresh.deinit();
    try validateBinding(allocator, io, fresh.root.directory, expected);
    const namespace_now = try fresh.root.directory.admitChild(expected.repository_directory_name.slice(), .directory);
    const current_location = switch (try run.readLocation(
        allocator,
        io,
        namespace,
        expected.review_repository_id,
        location.location.record.review_id,
        null,
    )) {
        .location => |value| value,
        .absent, .invalid => return error.Conflict,
    };
    const run_now = try namespace.admitChild(location.location.record.directory_name.slice(), .directory);
    if (!namespace_now.sameObject(namespace.metadata) or
        !current_location.eql(location.location) or
        !run_now.sameObject(selected.metadata) or
        !run_now.sameObject(location.run_metadata)) return error.Conflict;
}

fn completed(outcome: durable.Outcome(void)) !void {
    switch (outcome) {
        .not_completed => |err| return err,
        .completed => |result| if (result.after_error) |err| return err,
    }
}

fn missingLock(err: anyerror) anyerror {
    return if (err == error.FileNotFound) error.InvalidRun else err;
}

fn validateTrash(root: capability.DirectoryCapability, trash: capability.DirectoryCapability, repository_trash: capability.DirectoryCapability, repository_name: []const u8) !void {
    const trash_now = try root.admitChild(".trash", .directory);
    const repository_now = try trash.admitChild(repository_name, .directory);
    if (!trash_now.sameObject(trash.metadata) or !repository_now.sameObject(repository_trash.metadata)) return error.Conflict;
}

fn classify(err: anyerror) Failure {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.Locked, error.Conflict, error.PathAlreadyExists => .conflict,
        error.Unfinished => .unfinished,
        error.BindingChanged => .binding_changed,
        error.StoreUnavailable => .store_unavailable,
        error.UnsupportedPlatform, error.UnsupportedFilesystem, error.OperationUnsupported => .unsupported,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.InvalidRun, error.WrongType, error.WrongOwner, error.WrongMode, error.CrossDevice, error.MultipleLinks, error.SymLinkLoop, error.NotDir, error.FileSizeOutOfBounds => .run_invalid,
        else => .io_failed,
    };
}

test "review store deletion protects unfinished stale and locked Runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestFixture.init(tmp.dir);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var request = fixture.request;
    request.allow_unfinished = false;
    try std.testing.expectEqual(Failure.unfinished, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    request = fixture.request;
    request.artifacts.manifest_digest = review.Sha256Digest.hash("stale");
    try std.testing.expectEqual(Failure.conflict, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    request = fixture.request;
    request.store.root_inode +%= 1;
    try std.testing.expectEqual(Failure.binding_changed, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    request = fixture.request;
    request.store.repository_locator.inode +%= 1;
    try std.testing.expectEqual(Failure.binding_changed, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    request = fixture.request;
    request.review_id = try review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    try std.testing.expectEqual(Failure.not_found, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    request.review_id.bytes = [_]u8{0} ** 16;
    try std.testing.expectEqual(Failure.run_invalid, (try deleteRun(allocator, io, &fixture.context, request)).failure);
    var permission: TestFault = .{ .operation = .rename_preserve, .edge = .before, .failure = error.AccessDenied };
    const denied = try deleteWith(allocator, io, &fixture.context, fixture.request, .{ .context = &permission, .observe_fn = TestFault.observe });
    try std.testing.expectEqual(Failure.permission_denied, denied.failure);

    var root = fixture.context.openExisting().opened;
    defer root.deinit();
    var locks = try root.root.directory.openDirectory(".locks");
    defer locks.deinit();
    var repository_locks = try locks.openDirectory(&fixture.request.store.review_repository_id.canonical());
    defer repository_locks.deinit();
    var name: [41]u8 = undefined;
    _ = try std.fmt.bufPrint(&name, "{s}.lock", .{fixture.request.review_id.canonical()});
    for ([_][]const u8{ "publish.lock", &name }) |lock_name| {
        var lock = try core.acquireLock(io, repository_locks, lock_name, .try_lock);
        defer lock.deinit();
        try std.testing.expectEqual(Failure.conflict, (try deleteRun(allocator, io, &fixture.context, fixture.request)).failure);
    }
    const before = try fixture.store.readFileAlloc(io, "registry.json", allocator, .limited(1024 * 1024));
    defer allocator.free(before);
    try fixture.store.createDir(io, "untouched", .fromMode(0o700));
    try std.testing.expectEqual(Cleanup.complete, (try deleteRun(allocator, io, &fixture.context, fixture.request)).deleted);
    const after = try fixture.store.readFileAlloc(io, "registry.json", allocator, .limited(1024 * 1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    var untouched = try fixture.store.openDir(io, "untouched", .{});
    untouched.close(io);
    try std.testing.expectEqual(Failure.not_found, (try deleteRun(allocator, io, &fixture.context, fixture.request)).failure);
    try std.testing.expectEqual(@as(usize, 0), (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).cleaned);
    _ = try repository_locks.admitChild(&name, .regular_file);
    _ = try repository_locks.admitChild("publish.lock", .regular_file);
}

test "review store deletion refuses unknown unsafe and malformed artifacts" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    for (0..5) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestFixture.init(tmp.dir);
        defer fixture.deinit();
        var directory = try fixture.openRun();
        defer directory.close(io);
        switch (case) {
            0 => try directory.writeFile(io, .{ .sub_path = "unexpected", .data = "keep" }),
            1 => try directory.symLink(io, "manifest.json", "review_state.json", .{}),
            2 => try directory.createDir(io, "review_state.json", .fromMode(0o700)),
            3 => try directory.writeFile(io, .{ .sub_path = "result.json", .data = "{}", .flags = .{ .permissions = .fromMode(0o600) } }),
            4 => try directory.hardLink("manifest.json", fixture.store, "linked-manifest", io, .{}),
            else => unreachable,
        }
        try std.testing.expectEqual(Failure.run_invalid, (try deleteRun(allocator, io, &fixture.context, fixture.request)).failure);
        var still_present = try fixture.openRun();
        still_present.close(io);
    }
}

test "review store deletion fault boundaries preserve rename durability before unlink" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]TestFault{
        .{ .operation = .rename_preserve, .edge = .before },
        .{ .operation = .rename_preserve, .edge = .after },
        .{ .operation = .rename_preserve, .edge = .after, .failure = error.OutOfMemory },
        .{ .operation = .sync_directory, .edge = .before, .after_rename = true, .occurrence = 0 },
        .{ .operation = .sync_directory, .edge = .after, .after_rename = true, .occurrence = 0 },
        .{ .operation = .sync_directory, .edge = .before, .after_rename = true, .occurrence = 1 },
        .{ .operation = .sync_directory, .edge = .after, .after_rename = true, .occurrence = 1 },
        .{ .operation = .unlink_file, .edge = .before },
        .{ .operation = .unlink_file, .edge = .after },
        .{ .operation = .unlink_file, .edge = .before, .occurrence = 1 },
        .{ .operation = .unlink_file, .edge = .after, .occurrence = 1 },
        .{ .operation = .unlink_file, .edge = .before, .occurrence = 2 },
        .{ .operation = .unlink_file, .edge = .after, .occurrence = 2 },
        .{ .operation = .unlink_file, .edge = .before, .occurrence = 3 },
        .{ .operation = .unlink_file, .edge = .after, .occurrence = 3 },
        .{ .operation = .sync_directory, .edge = .before, .after_rename = true, .occurrence = 2 },
        .{ .operation = .sync_directory, .edge = .after, .after_rename = true, .occurrence = 2 },
        .{ .operation = .unlink_directory, .edge = .before },
        .{ .operation = .unlink_directory, .edge = .after },
        .{ .operation = .sync_directory, .edge = .before, .after_rename = true, .occurrence = 3 },
        .{ .operation = .sync_directory, .edge = .after, .after_rename = true, .occurrence = 3 },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try TestFixture.init(tmp.dir);
        defer fixture.deinit();
        var fault = case;
        try fixture.complete();
        const result = try deleteWith(allocator, io, &fixture.context, fixture.request, .{ .context = &fault, .observe_fn = TestFault.observe });
        try std.testing.expect(fault.fired);
        if (!fault.renamed) {
            try std.testing.expectEqual(Failure.io_failed, result.failure);
            var still_present = try fixture.openRun();
            still_present.close(io);
        } else {
            try std.testing.expectEqual(Failure.io_failed, result.deleted.pending);
            try std.testing.expectError(error.FileNotFound, fixture.openRun());
            if (case.operation == .rename_preserve or (case.operation == .sync_directory and case.occurrence < 2)) {
                try std.testing.expectEqual(@as(usize, 0), fault.unlinks);
                var trash = try fixture.openTrash();
                defer trash.close(io);
                var iterator = trash.iterate();
                const entry = (try iterator.next(io)).?;
                var residue = try trash.openDir(io, entry.name, .{});
                defer residue.close(io);
                const bytes = try residue.readFileAlloc(io, "manifest.json", allocator, .limited(1024 * 1024));
                defer allocator.free(bytes);
                try std.testing.expect(review.Sha256Digest.hash(bytes).eql(fixture.request.artifacts.manifest_digest));
            }
            _ = (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).cleaned;
            try std.testing.expectEqual(@as(usize, 0), (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).cleaned);
        }
    }
}

test "review store deletion cleanup refuses foreign names and unsafe residue" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        var orphan_tmp = std.testing.tmpDir(.{});
        defer orphan_tmp.cleanup();
        var orphan_fixture = try TestFixture.init(orphan_tmp.dir);
        defer orphan_fixture.deinit();
        var move_fault: TestFault = .{ .operation = .rename_preserve, .edge = .after };
        _ = try deleteWith(
            allocator,
            io,
            &orphan_fixture.context,
            orphan_fixture.request,
            .{ .context = &move_fault, .observe_fn = TestFault.observe },
        );
        var namespace = try orphan_fixture.store.openDir(
            io,
            orphan_fixture.request.store.repository_directory_name.slice(),
            .{},
        );
        defer namespace.close(io);
        const location_name = store_path.RunLocationName.format(orphan_fixture.request.review_id);
        try namespace.deleteFile(io, location_name.slice());
        const stopped = (try cleanupTrash(
            allocator,
            io,
            &orphan_fixture.context,
            orphan_fixture.request.store,
        )).stopped;
        try std.testing.expectEqual(Failure.run_invalid, stopped.failure);
        var trash = try orphan_fixture.openTrash();
        defer trash.close(io);
        var trash_entries = trash.iterate();
        try std.testing.expect((try trash_entries.next(io)) != null);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestFixture.init(tmp.dir);
    defer fixture.deinit();
    var fault: TestFault = .{ .operation = .rename_preserve, .edge = .after };
    _ = try deleteWith(allocator, io, &fixture.context, fixture.request, .{ .context = &fault, .observe_fn = TestFault.observe });
    var trash = try fixture.openTrash();
    defer trash.close(io);
    try trash.createDir(io, "foreign", .fromMode(0o700));
    try std.testing.expectEqual(Failure.run_invalid, (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).failure);
    try trash.deleteDir(io, "foreign");
    var barrier: TestFault = .{ .operation = .sync_directory, .edge = .before };
    try std.testing.expectError(error.InjectedDeletionFault, cleanupWith(allocator, io, &fixture.context, fixture.request.store, .{ .context = &barrier, .observe_fn = TestFault.observe }));
    try std.testing.expectEqual(@as(usize, 0), barrier.unlinks);
    var iterator = trash.iterate();
    const name = try allocator.dupe(u8, (try iterator.next(io)).?.name);
    defer allocator.free(name);
    var residue = try trash.openDir(io, name, .{});
    defer residue.close(io);
    try residue.symLink(io, "manifest.json", "review_state.json", .{});
    const stopped = (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).stopped;
    try std.testing.expectEqual(Failure.run_invalid, stopped.failure);
    try std.testing.expectEqual(@as(usize, 0), stopped.cleaned);
    try std.testing.expectEqual(@as(usize, 1), stopped.failed);
    const bytes = try residue.readFileAlloc(io, "manifest.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try std.testing.expect(review.Sha256Digest.hash(bytes).eql(fixture.request.artifacts.manifest_digest));
    try residue.deleteFile(io, "review_state.json");
    try std.testing.expectEqual(@as(usize, 1), (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).cleaned);
    for (0..max_trash_entries + 1) |index| {
        var bounded_name: TrashName = undefined;
        _ = try std.fmt.bufPrint(&bounded_name, "{s}-{x:0>32}", .{ fixture.request.review_id.canonical(), index });
        try trash.createDir(io, &bounded_name, .fromMode(0o700));
    }
    try std.testing.expectEqual(Failure.run_invalid, (try cleanupTrash(allocator, io, &fixture.context, fixture.request.store)).failure);
    var bounded_iterator = trash.iterate();
    var entries: usize = 0;
    while (try bounded_iterator.next(io)) |_| entries += 1;
    try std.testing.expectEqual(max_trash_entries + 1, entries);
}

test "review store deletion distinguishes missing and replaced Store roots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestFixture.init(tmp.dir);
    defer fixture.deinit();
    try tmp.dir.rename("store", tmp.dir, "old-store", io);
    try std.testing.expectEqual(Failure.not_found, (try deleteRun(allocator, io, &fixture.context, fixture.request)).failure);
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    try std.testing.expectEqual(Failure.binding_changed, (try deleteRun(allocator, io, &fixture.context, fixture.request)).failure);
    var original = try fixture.openRun();
    original.close(io);
}

const TestFault = struct {
    operation: durable.Operation,
    edge: durable.Edge,
    after_rename: bool = false,
    occurrence: usize = 0,
    seen: usize = 0,
    renamed: bool = false,
    fired: bool = false,
    unlinks: usize = 0,
    failure: anyerror = error.InjectedDeletionFault,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *TestFault = @ptrCast(@alignCast(context.?));
        if (step.operation == .rename_preserve and step.edge == .after) self.renamed = true;
        if (step.operation == .unlink_file and step.edge == .before) self.unlinks += 1;
        if (self.fired or (self.after_rename and !self.renamed) or step.operation != self.operation or step.edge != self.edge) return;
        defer self.seen += 1;
        if (self.seen == self.occurrence) {
            self.fired = true;
            return self.failure;
        }
    }
};

const TestFixture = struct {
    context: core.Context,
    store: std.Io.Dir,
    request: DeleteRequest,

    fn init(parent: std.Io.Dir) !TestFixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        try parent.createDir(io, "store", .fromMode(0o700));
        const path = try parent.realPathFileAlloc(io, "store", allocator);
        defer allocator.free(path);
        var context = try core.Context.initConfigured(allocator, path);
        errdefer context.deinit(allocator);
        const locator: review.GitCommonDirectoryLocator = .{ .device = 7, .inode = 11 };
        const prepared = (try core.prepareBinding(allocator, io, &context, .{ .locator = locator, .repository_path = "/test/repository", .repository_name = "repository" })).success;
        const oid = try review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
        const target: review.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
        const findings: review.FindingSet = .{ .schema_version = 1, .review_id = prepared.review_id, .created_at = "2026-09-10T00:00:00Z", .target = target, .producer = .{ .name = "test" }, .findings = &.{} };
        const findings_bytes = try findings.writeCanonical(allocator);
        defer allocator.free(findings_bytes);
        const manifest: review.ReviewRunManifest = .{ .schema_version = 1, .review_id = prepared.review_id, .review_repository_id = prepared.review_repository_id, .target = target, .created_at = findings.created_at, .display = null, .finding_count = 0, .producer = findings.producer, .findings_digest = review.Sha256Digest.hash(findings_bytes) };
        const manifest_bytes = try manifest.writeCanonical(allocator);
        defer allocator.free(manifest_bytes);
        const published = try core.publish(allocator, io, &context, .{ .locator = locator, .review_repository_id = prepared.review_repository_id, .review_id = prepared.review_id, .manifest_bytes = manifest_bytes, .findings_bytes = findings_bytes });
        try std.testing.expectEqual(core.PublishResult.success, published);
        var opened = context.openExisting().opened;
        defer opened.deinit();
        var namespace = try opened.root.directory.openDirectory(prepared.repository_directory_name.slice());
        defer namespace.deinit();
        var budget: run.ArtifactBudget = .{};
        var loaded = try run.loadValidated(
            allocator,
            io,
            namespace,
            prepared.review_repository_id,
            prepared.review_id,
            &budget,
        );
        defer loaded.deinit(allocator);
        const artifacts = switch (loaded) {
            .loaded => |*value| run.ArtifactSnapshot.fromLoaded(value),
            .invalid => return error.InvalidRun,
        };
        return .{ .context = context, .store = try parent.openDir(io, "store", .{}), .request = .{
            .store = .{ .root_device = opened.snapshot.device, .root_inode = opened.snapshot.inode, .repository_locator = locator, .review_repository_id = prepared.review_repository_id, .repository_display_name = prepared.repository_display_name, .repository_directory_name = prepared.repository_directory_name },
            .review_id = prepared.review_id,
            .artifacts = artifacts,
            .allow_unfinished = true,
        } };
    }

    fn deinit(self: *TestFixture) void {
        self.store.close(std.testing.io);
        self.context.deinit(std.testing.allocator);
    }

    fn complete(self: *TestFixture) !void {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var directory = try self.openRun();
        defer directory.close(io);
        const manifest_bytes = try directory.readFileAlloc(io, "manifest.json", allocator, .limited(1024 * 1024));
        defer allocator.free(manifest_bytes);
        var manifest = try review.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
        defer manifest.deinit();
        const draft: review.ReviewDraftState = .{ .schema_version = 1, .review_id = self.request.review_id, .target = manifest.value.target, .findings_digest = manifest.value.findings_digest, .revision = 1, .summary = null, .finding_dispositions = &.{}, .anchored_notes = &.{} };
        const result: review.RevisionReviewResult = .{ .schema_version = 1, .review_id = self.request.review_id, .target = manifest.value.target, .findings_digest = manifest.value.findings_digest, .result = .approved, .completed_at = "2026-09-10T00:00:01Z", .summary = null, .finding_dispositions = &.{}, .anchored_notes = &.{} };
        const draft_bytes = try draft.writeCanonical(allocator);
        defer allocator.free(draft_bytes);
        const result_bytes = try result.writeCanonical(allocator);
        defer allocator.free(result_bytes);
        try directory.writeFile(io, .{ .sub_path = "review_state.json", .data = draft_bytes, .flags = .{ .permissions = .fromMode(0o600) } });
        try directory.writeFile(io, .{ .sub_path = "result.json", .data = result_bytes, .flags = .{ .permissions = .fromMode(0o600) } });
        self.request.artifacts.draft_state = .valid;
        self.request.artifacts.draft_digest = review.Sha256Digest.hash(draft_bytes);
        self.request.artifacts.result_digest = review.Sha256Digest.hash(result_bytes);
        self.request.allow_unfinished = false;
    }

    fn openRun(self: *const TestFixture) !std.Io.Dir {
        var namespace = try self.store.openDir(std.testing.io, self.request.store.repository_directory_name.slice(), .{});
        defer namespace.close(std.testing.io);
        return namespace.openDir(
            std.testing.io,
            self.request.artifacts.run_location.?.location.record.directory_name.slice(),
            .{},
        );
    }

    fn openTrash(self: *const TestFixture) !std.Io.Dir {
        var trash = try self.store.openDir(std.testing.io, ".trash", .{});
        defer trash.close(std.testing.io);
        return trash.openDir(std.testing.io, &self.request.store.review_repository_id.canonical(), .{ .iterate = true });
    }
};
