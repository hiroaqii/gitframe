//! Descriptor-authorized discovery and durable identity of a Git common directory.

const std = @import("std");
const builtin = @import("builtin");
const committed_review = @import("../committed_review.zig");
const binding = @import("../committed_review/repository_binding.zig");
const fs = @import("../fs/capability.zig");
const durable = @import("../fs/durable.zig");
const git_command = @import("command.zig");
const root_capability = @import("../repo/root_capability.zig");

/// Machine-local value returned after descriptor-authorized discovery.
pub const GitCommonDirectoryLocator = binding.GitCommonDirectoryLocator;

const stdout_capture_bytes: usize = std.Io.Dir.max_path_bytes + 1;
const stderr_capture_bytes: usize = 8 * 1024;
const worktree_stdout_capture_bytes: usize = 1024 * 1024;
const marker_directory_name = "gitframe";
const marker_name = "repository-id-v1";
const marker_lock_name = "repository-id-v1.lock";
const marker_temp_name = ".repository-id-v1.tmp";
const marker_bytes: usize = 37;

pub const MarkerFailure = error{
    identity_missing,
    identity_invalid,
    identity_unavailable,
    identity_conflict,
};

pub const MarkerState = union(enum) {
    present: committed_review.RepositoryInstanceId,
    missing,
    invalid,
    unavailable,
};

const PathObservation = union(enum) {
    absent,
    repository: struct {
        locator: GitCommonDirectoryLocator,
        marker: MarkerState,
    },
    invalid,
    unavailable,
};

/// Observe a saved lease path without using it as positive binding authority.
fn observePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_path: []const u8,
) PathObservation {
    var capability = root_capability.RootCapability.openCanonical(canonical_path) catch |err| {
        if (err == error.FileNotFound) return .absent;
        return switch (err) {
            error.SymLinkLoop, error.NotDir, error.InvalidCanonicalRoot, error.RootNotAbsolute => .invalid,
            else => .unavailable,
        };
    };
    defer capability.deinit();
    const directory = commonDirectory(capability) catch return .unavailable;
    if (!filesystemSupported(directory)) return .invalid;
    return .{ .repository = .{
        .locator = .{ .device = capability.identity.device, .inode = capability.identity.inode },
        .marker = readMarker(allocator, io, directory),
    } };
}

/// Owned authority for one service call. Runtime locator bytes never persist.
pub const LocatedRepository = struct {
    common_directory: root_capability.RootCapability,
    canonical_path: []u8,
    locator: GitCommonDirectoryLocator,
    marker: MarkerState,
    testing_runtime: if (builtin.is_test) ?GitCommonDirectoryLocator else void = if (builtin.is_test) null else {},

    pub fn deinit(self: *LocatedRepository, allocator: std.mem.Allocator) void {
        self.common_directory.deinit();
        allocator.free(self.canonical_path);
        self.* = undefined;
    }

    pub fn instanceId(self: *const LocatedRepository) ?committed_review.RepositoryInstanceId {
        return switch (self.marker) {
            .present => |value| value,
            else => null,
        };
    }

    pub fn refreshMarker(self: *LocatedRepository, allocator: std.mem.Allocator, io: std.Io) void {
        const common = commonDirectory(self.common_directory) catch {
            self.marker = .unavailable;
            return;
        };
        self.marker = readMarker(allocator, io, common);
    }

    /// Create the marker only from explicit prepare while the Store registry
    /// lock is already held.
    pub fn ensureIdentity(
        self: *LocatedRepository,
        allocator: std.mem.Allocator,
        io: std.Io,
        observer: durable.Observer,
    ) MarkerFailure!committed_review.RepositoryInstanceId {
        switch (self.marker) {
            .present => {},
            .invalid => return error.identity_invalid,
            .unavailable => return error.identity_unavailable,
            .missing => {},
        }

        const common = commonDirectory(self.common_directory) catch return error.identity_unavailable;
        var marker_directory = acquireMarkerDirectory(io, common, observer) catch |err|
            return classifyMarkerError(err);
        defer marker_directory.deinit();

        var lock_acquisition = switch (durable.acquireRegularFile(
            marker_directory,
            marker_lock_name,
            markerAdmission(common.metadata, .regular_file),
            .fromMode(0o600),
            observer,
        )) {
            .not_completed => |err| return classifyMarkerError(err),
            .completed => |result| result,
        };
        defer lock_acquisition.value.file.deinit();
        if (lock_acquisition.after_error) |_| return error.identity_unavailable;
        if (lock_acquisition.value.disposition == .created) {
            completeMutation(durable.syncDirectory(io, marker_directory, observer)) catch
                return error.identity_unavailable;
        }
        lock_acquisition.value.file.lock(io, .exclusive) catch return error.identity_unavailable;
        defer lock_acquisition.value.file.unlock(io);

        const under_lock = readMarker(allocator, io, common);
        switch (under_lock) {
            .present => |value| {
                completeMutation(durable.syncDirectory(io, marker_directory, observer)) catch
                    return error.identity_unavailable;
                self.marker = .{ .present = value };
                return value;
            },
            .invalid => return error.identity_invalid,
            .unavailable => return error.identity_unavailable,
            .missing => {},
        }

        prepareTempMarker(allocator, io, marker_directory, common.metadata, observer) catch |err|
            return classifyMarkerError(err);
        const published = durable.movePreserving(
            io,
            marker_directory,
            marker_temp_name,
            marker_directory,
            marker_name,
            observer,
        );
        switch (published) {
            .not_completed => |err| if (err != error.PathAlreadyExists)
                return error.identity_unavailable,
            .completed => |result| {
                if (result.after_error != null) return error.identity_unavailable;
            },
        }
        completeMutation(durable.syncDirectory(io, marker_directory, observer)) catch
            return error.identity_unavailable;

        const final = readMarker(allocator, io, common);
        const final_identity = switch (final) {
            .present => |value| value,
            .missing => return error.identity_missing,
            .invalid => return error.identity_invalid,
            .unavailable => return error.identity_unavailable,
        };
        const metadata = fs.metadataForHandle(.{ .handle = self.common_directory.handle }) catch
            return error.identity_unavailable;
        if (metadata.device != self.locator.device or metadata.inode != self.locator.inode)
            return error.identity_unavailable;
        self.marker = .{ .present = final_identity };
        return final_identity;
    }

    pub fn revalidate(
        self: *const LocatedRepository,
        allocator: std.mem.Allocator,
        io: std.Io,
        context: git_command.DirectoryContext,
    ) (MarkerFailure || std.mem.Allocator.Error)!void {
        const expected = self.instanceId() orelse return error.identity_missing;
        var current = switch (try locate(allocator, io, context)) {
            .located => |value| value,
            .failure => return error.identity_unavailable,
        };
        defer current.deinit(allocator);
        if (builtin.is_test) {
            if (self.testing_runtime) |runtime| current.locator = runtime;
        }
        try validateResolved(self.locator, expected, current.locator, current.marker);
    }
};

fn validateResolved(
    expected_locator: GitCommonDirectoryLocator,
    expected_identity: committed_review.RepositoryInstanceId,
    current_locator: GitCommonDirectoryLocator,
    current_marker: MarkerState,
) MarkerFailure!void {
    if (!current_locator.eql(expected_locator)) return error.identity_conflict;
    const actual = switch (current_marker) {
        .present => |value| value,
        .missing => return error.identity_missing,
        .invalid => return error.identity_invalid,
        .unavailable => return error.identity_unavailable,
    };
    if (!actual.eql(expected_identity)) return error.identity_conflict;
}

pub const testing = if (builtin.is_test) struct {
    pub fn validateRuntime(
        expected_locator: GitCommonDirectoryLocator,
        expected_identity: committed_review.RepositoryInstanceId,
        current_locator: GitCommonDirectoryLocator,
        current_marker: MarkerState,
    ) MarkerFailure!void {
        return validateResolved(expected_locator, expected_identity, current_locator, current_marker);
    }
} else struct {};

/// Borrowed repository authority retained by one Store operation.
pub const OperationAuthority = struct {
    located: *const LocatedRepository,
    context: git_command.DirectoryContext,

    pub fn instanceId(self: OperationAuthority) ?committed_review.RepositoryInstanceId {
        return self.located.instanceId();
    }

    pub fn revalidate(
        self: OperationAuthority,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) (MarkerFailure || std.mem.Allocator.Error)!void {
        return self.located.revalidate(allocator, io, self.context);
    }
};

pub const PathLeaseAdmission = enum { accepted, transfer, move_required, duplicate, conflict };

pub fn admitPathLease(
    allocator: std.mem.Allocator,
    io: std.Io,
    located: *const LocatedRepository,
    saved_path: []const u8,
    expected_identity: committed_review.RepositoryInstanceId,
    stateful: bool,
) PathLeaseAdmission {
    if (std.mem.eql(u8, located.canonical_path, saved_path)) return .accepted;
    return switch (observePath(allocator, io, saved_path)) {
        .absent => if (stateful) .transfer else .move_required,
        .invalid, .unavailable => .conflict,
        .repository => |saved| if (saved.locator.eql(located.locator))
            .accepted
        else switch (saved.marker) {
            .present => |saved_id| if (saved_id.eql(expected_identity))
                .duplicate
            else if (stateful)
                .transfer
            else
                .move_required,
            .missing, .invalid, .unavailable => .conflict,
        },
    };
}

/// Operation-specific locator terminals; no failure contains a partial locator.
pub const RepositoryLocatorFailure = enum {
    invalid_repository,
    invalid_common_directory,
    common_directory_unavailable,
    git_command_failed,
    unsupported_platform,
};

/// Complete physical locator or one locator-specific terminal.
pub const RepositoryLocatorResult = union(enum) {
    located: LocatedRepository,
    failure: RepositoryLocatorFailure,

    pub fn deinit(self: *RepositoryLocatorResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .located => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .git_command_failed };
    }
};

pub const MainWorktreeResult = union(enum) {
    basename: []u8,
    unavailable,

    pub fn deinit(self: *MainWorktreeResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .basename => |value| allocator.free(value),
            .unavailable => {},
        }
        self.* = .unavailable;
    }
};

/// Resolve and open the common directory for the borrowed repository context.
/// Child captures and descriptors are released before the value result escapes.
pub fn locate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!RepositoryLocatorResult {
    const argv = [_][]const u8{
        "git",
        "--no-optional-locks",
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    };
    var command_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(stdout_capture_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer command_result.deinit(allocator);
    const completed = switch (command_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .git_command_failed },
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return .{ .failure = .invalid_repository },
        else => return .{ .failure = .git_command_failed },
    }
    return locateGitOutput(allocator, io, completed.stdout);
}

/// Read Git's first porcelain worktree record. Git defines that record as the
/// main worktree; linked-worktree cwd therefore resolves to the same basename.
pub fn mainWorktreeBasename(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!MainWorktreeResult {
    return mainWorktreeBasenameUsing(allocator, io, context, "git");
}

fn mainWorktreeBasenameUsing(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    executable: []const u8,
) std.mem.Allocator.Error!MainWorktreeResult {
    const argv = [_][]const u8{
        executable,
        "--no-optional-locks",
        "worktree",
        "list",
        "--porcelain",
        "-z",
    };
    var command_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(worktree_stdout_capture_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer command_result.deinit(allocator);
    const completed = switch (command_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .unavailable,
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return .unavailable,
        else => return .unavailable,
    }
    const path = firstMainWorktreePath(completed.stdout) orelse return .unavailable;
    var capability = root_capability.RootCapability.openCanonical(path) catch return .unavailable;
    defer capability.deinit();
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .unavailable;
    const basename = path[separator + 1 ..];
    return .{ .basename = try allocator.dupe(u8, basename) };
}

fn firstMainWorktreePath(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return null;
    const record_end = std.mem.indexOf(u8, bytes, "\x00\x00") orelse return null;
    var fields = std.mem.splitScalar(u8, bytes[0..record_end], 0);
    const worktree_field = fields.next() orelse return null;
    const prefix = "worktree ";
    if (!std.mem.startsWith(u8, worktree_field, prefix)) return null;
    const path = canonicalAbsolutePath(worktree_field[prefix.len..]) orelse return null;
    if (path.len == 1) return null;

    while (fields.next()) |field| {
        if (field.len == 0) return null;
        if (std.mem.eql(u8, field, "bare")) return null;
    }
    return path;
}

fn locateGitOutput(allocator: std.mem.Allocator, io: std.Io, stdout: []const u8) std.mem.Allocator.Error!RepositoryLocatorResult {
    const common_directory = singleAbsolutePath(stdout) orelse
        return .{ .failure = .invalid_common_directory };
    return locateCommonDirectory(allocator, io, common_directory);
}

fn locateCommonDirectory(allocator: std.mem.Allocator, io: std.Io, common_directory: []const u8) std.mem.Allocator.Error!RepositoryLocatorResult {
    var capability = root_capability.RootCapability.openCanonical(common_directory) catch |err| {
        return .{ .failure = if (err == error.UnsupportedPlatform)
            .unsupported_platform
        else
            .common_directory_unavailable };
    };
    var transferred = false;
    defer if (!transferred) capability.deinit();
    const directory = commonDirectory(capability) catch
        return .{ .failure = .common_directory_unavailable };
    if (!filesystemSupported(directory)) return .{ .failure = .common_directory_unavailable };
    const path = try allocator.dupe(u8, common_directory);
    transferred = true;
    return .{ .located = .{
        .common_directory = capability,
        .canonical_path = path,
        .locator = .{
            .device = capability.identity.device,
            .inode = capability.identity.inode,
        },
        .marker = readMarker(allocator, io, directory),
    } };
}

fn commonDirectory(capability: root_capability.RootCapability) !fs.Directory {
    const descriptor: fs.Descriptor = .{ .handle = capability.handle };
    return .{ .descriptor = descriptor, .metadata = try fs.metadataForHandle(descriptor) };
}

fn markerAdmission(common: fs.Metadata, expected: fs.ExpectedKind) fs.Admission {
    return .{
        .expected = expected,
        .device = common.device,
        .uid = effectiveUid(),
        .mode = if (expected == .directory) 0o700 else 0o600,
        .require_single_link = expected == .regular_file,
    };
}

fn effectiveUid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.geteuid()),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn filesystemSupported(directory: fs.Directory) bool {
    const metadata = fs.filesystemMetadata(directory) catch return false;
    return switch (metadata) {
        .linux => |value| if (value.magic < 0) false else switch (@as(u64, @intCast(value.magic))) {
            0x0000ef53, 0x58465342, 0x9123683e, 0xf2f52010, 0x2fc12fc1, 0x01021994, 0x858458f6, 0x794c7630 => true,
            else => false,
        },
        .darwin => |value| blk: {
            const read_only: u32 = 0x00000001;
            const local: u32 = 0x00001000;
            if ((value.flags & local) == 0 or (value.flags & read_only) != 0) break :blk false;
            const name = std.mem.sliceTo(&value.type_name, 0);
            break :blk !std.ascii.eqlIgnoreCase(name, "fusefs") and
                !std.ascii.eqlIgnoreCase(name, "osxfuse") and
                !std.ascii.eqlIgnoreCase(name, "macfuse");
        },
    };
}

fn readMarker(allocator: std.mem.Allocator, io: std.Io, common: fs.Directory) MarkerState {
    var directory = common.openDirectory(marker_directory_name) catch |err|
        return markerStateFromReadError(err);
    defer directory.deinit();
    fs.admitMetadata(directory.metadata, markerAdmission(common.metadata, .directory)) catch
        return .invalid;
    const bytes = directory.readRegularAlloc(
        allocator,
        io,
        marker_name,
        markerAdmission(common.metadata, .regular_file),
        marker_bytes,
    ) catch |err| return markerStateFromReadError(err);
    defer allocator.free(bytes);
    if (bytes.len != marker_bytes or bytes[marker_bytes - 1] != '\n') return .invalid;
    const instance_id = committed_review.RepositoryInstanceId.parse(bytes[0 .. marker_bytes - 1]) catch
        return .invalid;
    return .{ .present = instance_id };
}

fn markerStateFromReadError(err: anyerror) MarkerState {
    if (err == error.FileNotFound) return .missing;
    return switch (classifyMarkerError(err)) {
        error.identity_invalid => .invalid,
        error.identity_missing => .missing,
        error.identity_unavailable => .unavailable,
        error.identity_conflict => .invalid,
    };
}

fn classifyMarkerError(err: anyerror) MarkerFailure {
    return switch (err) {
        error.FileNotFound => error.identity_missing,
        error.WrongType,
        error.WrongOwner,
        error.WrongMode,
        error.CrossDevice,
        error.MultipleLinks,
        error.SymLinkLoop,
        error.NotDir,
        error.FileSizeOutOfBounds,
        error.InvalidUuid,
        => error.identity_invalid,
        else => error.identity_unavailable,
    };
}

fn acquireMarkerDirectory(
    io: std.Io,
    common: fs.Directory,
    observer: durable.Observer,
) !fs.Directory {
    const acquired = switch (durable.acquireDirectory(
        io,
        common,
        marker_directory_name,
        markerAdmission(common.metadata, .directory),
        .fromMode(0o700),
        observer,
    )) {
        .not_completed => |err| return err,
        .completed => |result| result,
    };
    var directory = acquired.value.directory orelse return error.MarkerDirectoryUnavailable;
    errdefer directory.deinit();
    if (acquired.after_error) |err| return err;
    return directory;
}

fn prepareTempMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: fs.Directory,
    common_metadata: fs.Metadata,
    observer: durable.Observer,
) !void {
    const admission = markerAdmission(common_metadata, .regular_file);
    if (directory.openRegularFileExisting(marker_temp_name, admission)) |opened| {
        var file = opened;
        defer file.deinit();
        const size = file.metadata.size;
        if (size > marker_bytes) return error.FileSizeOutOfBounds;
        const bytes = file.readRegularAlloc(allocator, io, admission, marker_bytes) catch |err| {
            if (err != error.FileSizeOutOfBounds) return err;
            try completeMutation(durable.removeFile(io, directory, marker_temp_name, observer));
            try completeMutation(durable.syncDirectory(io, directory, observer));
            return createTempMarker(io, directory, observer);
        };
        defer allocator.free(bytes);
        if (bytes.len == marker_bytes and bytes[marker_bytes - 1] == '\n') {
            if (committed_review.RepositoryInstanceId.parse(bytes[0 .. marker_bytes - 1])) |_| {
                try completeMutation(durable.syncFile(io, file, observer));
                const current = try directory.admitChild(marker_temp_name, admission);
                if (!current.sameObject(file.metadata)) return error.FileChangedWhileReading;
                return;
            } else |_| {}
        }
        try completeMutation(durable.removeFile(io, directory, marker_temp_name, observer));
        try completeMutation(durable.syncDirectory(io, directory, observer));
    } else |err| if (err != error.FileNotFound) return err;
    return createTempMarker(io, directory, observer);
}

fn createTempMarker(
    io: std.Io,
    directory: fs.Directory,
    observer: durable.Observer,
) !void {
    var identity: committed_review.RepositoryInstanceId = undefined;
    try io.randomSecure(&identity.bytes);
    identity.bytes[6] = (identity.bytes[6] & 0x0f) | 0x40;
    identity.bytes[8] = (identity.bytes[8] & 0x3f) | 0x80;
    const canonical = identity.canonical();
    var bytes: [marker_bytes]u8 = undefined;
    @memcpy(bytes[0..36], &canonical);
    bytes[36] = '\n';
    var file = switch (durable.createFile(directory, marker_temp_name, .fromMode(0o600), observer)) {
        .not_completed => |err| return err,
        .completed => |result| blk: {
            if (result.after_error) |err| {
                var created = result.value;
                created.deinit();
                return err;
            }
            break :blk result.value;
        },
    };
    defer file.deinit();
    try completeMutation(durable.writeAll(io, file, &bytes, observer));
    try completeMutation(durable.syncFile(io, file, observer));
}

fn completeMutation(outcome: durable.Outcome(void)) !void {
    switch (outcome) {
        .not_completed => |err| return err,
        .completed => |result| if (result.after_error) |err| return err,
    }
}

fn singleAbsolutePath(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return null;
    const path = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return null;
    return canonicalAbsolutePath(path);
}

fn canonicalAbsolutePath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path.len >= std.Io.Dir.max_path_bytes or path[0] != '/') return null;
    if (path.len > 1) {
        var components = std.mem.splitScalar(u8, path[1..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, "..")) return null;
        }
    }
    return path;
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

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return error.GitCommandFailed;
}

fn openCapabilityAt(io: std.Io, parent: std.Io.Dir, sub_path: []const u8) !root_capability.RootCapability {
    const path = try parent.realPathFileAlloc(io, sub_path, std.testing.allocator);
    defer std.testing.allocator.free(path);
    return root_capability.RootCapability.openCanonical(path);
}

fn locateAt(
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) !RepositoryLocatorResult {
    var root = try openCapabilityAt(io, parent, sub_path);
    defer root.deinit();
    return locate(std.testing.allocator, io, .{ .cwd = root.dir(), .environment = environment });
}

fn expectLocator(result: *RepositoryLocatorResult) !GitCommonDirectoryLocator {
    return switch (result.*) {
        .located => |*located| located.locator,
        .failure => error.ExpectedRepositoryLocator,
    };
}

fn locateLocatorAt(
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    environment: *const git_command.LocalGitEnvironment,
) !GitCommonDirectoryLocator {
    var result = try locateAt(io, parent, sub_path, environment);
    defer result.deinit(std.testing.allocator);
    return expectLocator(&result);
}

test "repository instance marker is read-only until prepare and stable afterward" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();

    var first = try locateAt(io, tmp.dir, "repo", &environment);
    defer first.deinit(allocator);
    const located = switch (first) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    try std.testing.expect(located.marker == .missing);
    try std.testing.expectError(error.FileNotFound, repo.access(io, ".git/gitframe", .{}));

    const identity = try located.ensureIdentity(allocator, io, .{});
    const canonical = identity.canonical();
    const marker = try repo.readFileAlloc(io, ".git/gitframe/repository-id-v1", allocator, .limited(marker_bytes + 1));
    defer allocator.free(marker);
    try std.testing.expectEqual(marker_bytes, marker.len);
    try std.testing.expectEqualSlices(u8, &canonical, marker[0..36]);
    try std.testing.expectEqual(@as(u8, '\n'), marker[36]);

    var second = try locateAt(io, tmp.dir, "repo", &environment);
    defer second.deinit(allocator);
    const reopened = switch (second) {
        .located => |*value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };
    try std.testing.expect(reopened.instanceId().?.eql(identity));
    try reopened.revalidate(allocator, io, .{ .cwd = repo, .environment = &environment });

    var reboot_locator = reopened.locator;
    reboot_locator.device +%= 1;
    try validateResolved(reboot_locator, identity, reboot_locator, .{ .present = identity });
    try std.testing.expectError(
        error.identity_conflict,
        validateResolved(reopened.locator, identity, reboot_locator, .{ .present = identity }),
    );
}

test "repository instance marker rejects unsafe type mode links size and bytes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    for (0..5) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .fromMode(0o700));
        var repo = try tmp.dir.openDir(io, "repo", .{});
        defer repo.close(io);
        try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
        try repo.createDir(io, ".git/gitframe", .fromMode(0o700));
        switch (case) {
            0 => try repo.createDir(io, ".git/gitframe/repository-id-v1", .fromMode(0o700)),
            1 => try repo.writeFile(io, .{
                .sub_path = ".git/gitframe/repository-id-v1",
                .data = "123e4567-e89b-42d3-a456-426614174010\n",
                .flags = .{ .permissions = .fromMode(0o644) },
            }),
            2 => {
                try repo.writeFile(io, .{
                    .sub_path = ".git/gitframe/repository-id-v1",
                    .data = "123e4567-e89b-42d3-a456-426614174010\n",
                    .flags = .{ .permissions = .fromMode(0o600) },
                });
                try repo.hardLink(
                    ".git/gitframe/repository-id-v1",
                    repo,
                    ".git/gitframe/alias",
                    io,
                    .{},
                );
            },
            3 => try repo.writeFile(io, .{
                .sub_path = ".git/gitframe/repository-id-v1",
                .data = "123e4567-e89b-42d3-a456-426614174010-extra\n",
                .flags = .{ .permissions = .fromMode(0o600) },
            }),
            4 => try repo.writeFile(io, .{
                .sub_path = ".git/gitframe/repository-id-v1",
                .data = "not-a-canonical-uuid-v4-marker-value\n",
                .flags = .{ .permissions = .fromMode(0o600) },
            }),
            else => unreachable,
        }
        var result = try locateAt(io, tmp.dir, "repo", &environment);
        defer result.deinit(allocator);
        const located = switch (result) {
            .located => |*value| value,
            .failure => return error.ExpectedRepositoryLocator,
        };
        try std.testing.expect(located.marker == .invalid);
        try std.testing.expectError(error.identity_invalid, located.ensureIdentity(allocator, io, .{}));
    }
}

const MarkerPostRenameFault = struct {
    renamed: bool = false,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *MarkerPostRenameFault = @ptrCast(@alignCast(context.?));
        if (step.operation == .rename_preserve and step.edge == .after) {
            self.renamed = true;
            return;
        }
        if (self.renamed and step.operation == .sync_directory and step.edge == .before)
            return error.InjectedMarkerSyncFault;
    }
};

const MarkerTempReplacement = struct {
    io: std.Io,
    repository: std.Io.Dir,
    fired: bool = false,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.fired or step.operation != .sync_file or step.edge != .before) return;
        self.fired = true;
        try self.repository.deleteFile(self.io, ".git/gitframe/.repository-id-v1.tmp");
        try self.repository.writeFile(self.io, .{
            .sub_path = ".git/gitframe/.repository-id-v1.tmp",
            .data = "923e4567-e89b-42d3-a456-426614174010\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }
};

test "repository instance marker adopts fixed temp and reuses a post-rename winner" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    for (0..3) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .fromMode(0o700));
        var repo = try tmp.dir.openDir(io, "repo", .{});
        defer repo.close(io);
        try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
        if (case == 0 or case == 2) {
            try repo.createDir(io, ".git/gitframe", .fromMode(0o700));
            try repo.writeFile(io, .{
                .sub_path = ".git/gitframe/.repository-id-v1.tmp",
                .data = "123e4567-e89b-42d3-a456-426614174010\n",
                .flags = .{ .permissions = .fromMode(0o600) },
            });
        }
        var result = try locateAt(io, tmp.dir, "repo", &environment);
        defer result.deinit(allocator);
        const located = switch (result) {
            .located => |*value| value,
            .failure => return error.ExpectedRepositoryLocator,
        };
        if (case == 0) {
            const expected = try committed_review.RepositoryInstanceId.parse("123e4567-e89b-42d3-a456-426614174010");
            try std.testing.expect((try located.ensureIdentity(allocator, io, .{})).eql(expected));
            try std.testing.expectError(error.FileNotFound, repo.access(io, ".git/gitframe/.repository-id-v1.tmp", .{}));
        } else if (case == 1) {
            var fault: MarkerPostRenameFault = .{};
            try std.testing.expectError(
                error.identity_unavailable,
                located.ensureIdentity(allocator, io, .{ .context = &fault, .observe_fn = MarkerPostRenameFault.observe }),
            );
            try std.testing.expect(fault.renamed);
            located.refreshMarker(allocator, io);
            const winner = located.instanceId() orelse return error.ExpectedRepositoryInstanceId;
            try std.testing.expect((try located.ensureIdentity(allocator, io, .{})).eql(winner));
        } else {
            var replacement: MarkerTempReplacement = .{ .io = io, .repository = repo };
            try std.testing.expectError(
                error.identity_unavailable,
                located.ensureIdentity(allocator, io, .{
                    .context = &replacement,
                    .observe_fn = MarkerTempReplacement.observe,
                }),
            );
            try std.testing.expect(replacement.fired);
            try std.testing.expectError(error.FileNotFound, repo.access(io, ".git/gitframe/repository-id-v1", .{}));
            const foreign = try repo.readFileAlloc(
                io,
                ".git/gitframe/.repository-id-v1.tmp",
                allocator,
                .limited(marker_bytes + 1),
            );
            defer allocator.free(foreign);
            try std.testing.expectEqualStrings("923e4567-e89b-42d3-a456-426614174010\n", foreign);
        }
    }
}

test "repository instance marker retries every publication edge with one durable winner" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { step: durable.Step, occurrence: usize = 0 }{
        .{ .step = .{ .operation = .create_directory, .edge = .before } },
        .{ .step = .{ .operation = .create_directory, .edge = .after } },
        .{ .step = .{ .operation = .sync_directory, .edge = .before } },
        .{ .step = .{ .operation = .sync_directory, .edge = .after } },
        .{ .step = .{ .operation = .create_file, .edge = .before } },
        .{ .step = .{ .operation = .create_file, .edge = .after } },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .create_file, .edge = .before }, .occurrence = 1 },
        .{ .step = .{ .operation = .create_file, .edge = .after }, .occurrence = 1 },
        .{ .step = .{ .operation = .write, .edge = .before } },
        .{ .step = .{ .operation = .write, .edge = .after } },
        .{ .step = .{ .operation = .sync_file, .edge = .before } },
        .{ .step = .{ .operation = .sync_file, .edge = .after } },
        .{ .step = .{ .operation = .rename_preserve, .edge = .before } },
        .{ .step = .{ .operation = .rename_preserve, .edge = .after } },
        .{ .step = .{ .operation = .sync_directory, .edge = .before }, .occurrence = 2 },
        .{ .step = .{ .operation = .sync_directory, .edge = .after }, .occurrence = 2 },
    };
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "repo", .fromMode(0o700));
        var repo = try tmp.dir.openDir(io, "repo", .{});
        defer repo.close(io);
        try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
        var result = try locateAt(io, tmp.dir, "repo", &environment);
        defer result.deinit(allocator);
        const located = switch (result) {
            .located => |*value| value,
            .failure => return error.ExpectedRepositoryLocator,
        };
        var fault: MarkerStepFault = .{ .selected = case.step, .occurrence = case.occurrence };
        try std.testing.expectError(error.identity_unavailable, located.ensureIdentity(allocator, io, fault.observer()));
        try std.testing.expect(fault.seen > case.occurrence);
        const visible = try visibleMarkerIdentity(allocator, io, repo);
        const winner = try located.ensureIdentity(allocator, io, .{});
        if (visible) |expected| try std.testing.expect(winner.eql(expected));
        located.refreshMarker(allocator, io);
        try std.testing.expect(located.instanceId().?.eql(winner));
        try std.testing.expectError(error.FileNotFound, repo.access(io, ".git/gitframe/.repository-id-v1.tmp", .{}));
    }
}

const MarkerStepFault = struct {
    selected: durable.Step,
    occurrence: usize,
    seen: usize = 0,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (step.operation != self.selected.operation or step.edge != self.selected.edge) return;
        defer self.seen += 1;
        if (self.seen == self.occurrence) return error.InjectedMarkerFault;
    }

    fn observer(self: *@This()) durable.Observer {
        return .{ .context = self, .observe_fn = observe };
    }
};

fn visibleMarkerIdentity(allocator: std.mem.Allocator, io: std.Io, repository: std.Io.Dir) !?committed_review.RepositoryInstanceId {
    const paths = [_][]const u8{ ".git/gitframe/repository-id-v1", ".git/gitframe/.repository-id-v1.tmp" };
    for (paths) |path| {
        const bytes = repository.readFileAlloc(io, path, allocator, .limited(marker_bytes + 1)) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(bytes);
        if (bytes.len == marker_bytes and bytes[marker_bytes - 1] == '\n')
            return committed_review.RepositoryInstanceId.parse(bytes[0 .. marker_bytes - 1]) catch null;
    }
    return null;
}

test "linked worktrees share one Git common-directory locator" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "main", .default_dir);
    var main = try tmp.dir.openDir(io, "main", .{});
    defer main.close(io);
    try runTestGit(io, main, &.{ "git", "init", "--initial-branch=main" });
    try main.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, main, &.{ "git", "add", "file" });
    try runTestGit(io, main, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, main, &.{ "git", "worktree", "add", "../linked", "-b", "linked" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const main_locator = try locateLocatorAt(io, tmp.dir, "main", &environment);
    const linked_locator = try locateLocatorAt(io, tmp.dir, "linked", &environment);
    try std.testing.expect(main_locator.eql(linked_locator));
}

test "distinct clones of one remote keep distinct physical locators" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--bare", "remote.git" });
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "remote.git", "clone-a" });
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "remote.git", "clone-b" });

    var clone_a = try tmp.dir.openDir(io, "clone-a", .{});
    defer clone_a.close(io);
    var clone_b = try tmp.dir.openDir(io, "clone-b", .{});
    defer clone_b.close(io);
    const first_remote = try testGitOutput(io, clone_a, &.{ "git", "config", "--get", "remote.origin.url" });
    defer std.testing.allocator.free(first_remote);
    const second_remote = try testGitOutput(io, clone_b, &.{ "git", "config", "--get", "remote.origin.url" });
    defer std.testing.allocator.free(second_remote);
    try std.testing.expectEqualStrings(first_remote, second_remote);

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var clone_a_root = try openCapabilityAt(io, tmp.dir, "clone-a");
    defer clone_a_root.deinit();
    var clone_b_root = try openCapabilityAt(io, tmp.dir, "clone-b");
    defer clone_b_root.deinit();
    var clone_a_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = clone_a_root.dir(), .environment = &environment });
    defer clone_a_name.deinit(std.testing.allocator);
    var clone_b_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = clone_b_root.dir(), .environment = &environment });
    defer clone_b_name.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clone-a", clone_a_name.basename);
    try std.testing.expectEqualStrings("clone-b", clone_b_name.basename);
    const first = try locateLocatorAt(io, tmp.dir, "clone-a", &environment);
    const second = try locateLocatorAt(io, tmp.dir, "clone-b", &environment);
    try std.testing.expect(!first.eql(second));
}

test "same-filesystem repository rename retains the common-directory locator" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const before = try locateLocatorAt(io, tmp.dir, "repo", &environment);
    try tmp.dir.rename("repo", tmp.dir, "moved", io);
    const after = try locateLocatorAt(io, tmp.dir, "moved", &environment);
    try std.testing.expect(before.eql(after));
}

test "common-directory symlink redirection and non-repository input fail closed" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.rename(".git", repo, "actual-git", io);
    try repo.symLink(io, "actual-git", ".git", .{ .is_directory = true });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", std.testing.allocator);
    defer std.testing.allocator.free(repo_path);
    const linked_common_directory = try std.fs.path.join(std.testing.allocator, &.{ repo_path, ".git" });
    defer std.testing.allocator.free(linked_common_directory);
    const redirected = try locateCommonDirectory(std.testing.allocator, io, linked_common_directory);
    try std.testing.expect(redirected == .failure);
    try std.testing.expectEqual(RepositoryLocatorFailure.common_directory_unavailable, redirected.failure);

    try tmp.dir.createDir(io, "not-a-repository", .default_dir);
    var not_a_repository = try tmp.dir.openDir(io, "not-a-repository", .{});
    defer not_a_repository.close(io);
    try not_a_repository.writeFile(io, .{ .sub_path = ".git", .data = "not a gitdir record\n" });
    const invalid = try locateAt(io, tmp.dir, "not-a-repository", &environment);
    try std.testing.expect(invalid == .failure);
    try std.testing.expectEqual(RepositoryLocatorFailure.invalid_repository, invalid.failure);
}

test "unsupported common-directory resolution closes every acquired descriptor" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const before = try openDescriptorCount(io);
    for (0..128) |_| {
        var result = try locateCommonDirectory(std.testing.allocator, io, "/proc");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(RepositoryLocatorFailure.common_directory_unavailable, result.failure);
    }
    try std.testing.expectEqual(before, try openDescriptorCount(io));
}

fn openDescriptorCount(io: std.Io) !usize {
    var directory = try std.Io.Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });
    defer directory.close(io);
    var count: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "common-directory output parser is absolute single-line and bounded" {
    try std.testing.expectEqualStrings("/repo/.git", singleAbsolutePath("/repo/.git\n").?);
    try std.testing.expect(singleAbsolutePath("repo/.git\n") == null);
    try std.testing.expect(singleAbsolutePath("/repo/.git") == null);
    try std.testing.expect(singleAbsolutePath("/repo\n/.git\n") == null);
    try std.testing.expect(singleAbsolutePath("/repo\r\n") == null);

    const noncanonical = [_][]const u8{
        "/repo/./.git\n",
        "/repo/../other\n",
        "/repo//.git\n",
        "/repo/.git/\n",
    };
    for (noncanonical) |output| {
        try std.testing.expect(singleAbsolutePath(output) == null);
        const result = try locateGitOutput(std.testing.allocator, std.testing.io, output);
        try std.testing.expect(result == .failure);
        try std.testing.expectEqual(RepositoryLocatorFailure.invalid_common_directory, result.failure);
    }

    const boundary = try std.testing.allocator.alloc(u8, std.Io.Dir.max_path_bytes + 1);
    defer std.testing.allocator.free(boundary);
    @memset(boundary, 'a');
    boundary[0] = '/';
    boundary[std.Io.Dir.max_path_bytes - 1] = '\n';
    try std.testing.expectEqual(
        std.Io.Dir.max_path_bytes - 1,
        singleAbsolutePath(boundary[0..std.Io.Dir.max_path_bytes]).?.len,
    );
    boundary[std.Io.Dir.max_path_bytes - 1] = 'a';
    boundary[std.Io.Dir.max_path_bytes] = '\n';
    try std.testing.expect(singleAbsolutePath(boundary) == null);
}

test "review repository name parser returns only a finite canonical first non-bare worktree path" {
    const output = "worktree /work/Main-Repo\x00HEAD 0123456789abcdef\x00branch refs/heads/main\x00\x00" ++
        "worktree /work/linked\x00HEAD fedcba9876543210\x00detached\x00\x00";
    try std.testing.expectEqualStrings("/work/Main-Repo", firstMainWorktreePath(output).?);
    try std.testing.expect(firstMainWorktreePath("worktree /work/bare.git\x00bare\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree relative\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/repo\x00HEAD x\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/./repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/../repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work//repo\x00HEAD x\x00\x00") == null);
    try std.testing.expect(firstMainWorktreePath("worktree /work/repo/\x00HEAD x\x00\x00") == null);

    const oversized_path = try std.testing.allocator.alloc(u8, std.Io.Dir.max_path_bytes);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    oversized_path[0] = '/';
    const oversized_output = try std.fmt.allocPrint(
        std.testing.allocator,
        "worktree {s}\x00HEAD x\x00\x00",
        .{oversized_path},
    );
    defer std.testing.allocator.free(oversized_output);
    try std.testing.expect(firstMainWorktreePath(oversized_output) == null);
}

test "review repository name discovery rejects fake Git paths that cannot be admitted" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "main", .default_dir);
    try tmp.dir.symLink(io, "main", "linked-main", .{ .is_directory = true });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    const nonexistent_path = try std.fs.path.join(allocator, &.{ root_path, "missing-main" });
    defer allocator.free(nonexistent_path);
    const linked_path = try std.fs.path.join(allocator, &.{ root_path, "linked-main" });
    defer allocator.free(linked_path);
    const noncanonical_path = try std.fmt.allocPrint(allocator, "{s}/main/../main", .{root_path});
    defer allocator.free(noncanonical_path);
    const oversized_path = try allocator.alloc(u8, std.Io.Dir.max_path_bytes);
    defer allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    oversized_path[0] = '/';
    const executable = try std.fs.path.join(allocator, &.{ root_path, "fake-git" });
    defer allocator.free(executable);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();

    for ([_][]const u8{ nonexistent_path, linked_path, noncanonical_path, oversized_path }) |invalid_path| {
        const script = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nprintf 'worktree %s\\000HEAD 0123456789abcdef0123456789abcdef01234567\\000branch refs/heads/main\\000\\000' \"{s}\"\n",
            .{invalid_path},
        );
        defer allocator.free(script);
        try tmp.dir.writeFile(io, .{
            .sub_path = "fake-git",
            .data = script,
            .flags = .{ .permissions = .fromMode(0o700) },
        });
        var discovered = try mainWorktreeBasenameUsing(allocator, io, .{
            .cwd = root.dir(),
            .environment = &environment,
        }, executable);
        defer discovered.deinit(allocator);
        try std.testing.expect(discovered == .unavailable);
    }
}

test "review repository name discovery is stable from linked worktrees" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "Main-Repo", .default_dir);
    var main = try tmp.dir.openDir(io, "Main-Repo", .{});
    defer main.close(io);
    try runTestGit(io, main, &.{ "git", "init", "--initial-branch=main" });
    try main.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, main, &.{ "git", "add", "file" });
    try runTestGit(io, main, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, main, &.{ "git", "worktree", "add", "../linked-name", "-b", "linked-name" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var main_root = try openCapabilityAt(io, tmp.dir, "Main-Repo");
    defer main_root.deinit();
    var linked_root = try openCapabilityAt(io, tmp.dir, "linked-name");
    defer linked_root.deinit();
    var from_main = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = main_root.dir(), .environment = &environment });
    defer from_main.deinit(std.testing.allocator);
    var from_linked = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = linked_root.dir(), .environment = &environment });
    defer from_linked.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Main-Repo", from_main.basename);
    try std.testing.expectEqualStrings("Main-Repo", from_linked.basename);
}

test "review repository name discovery handles bare separate-git-dir and submodule repositories" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--bare", "Bare.git" });
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main", "--separate-git-dir", "Separate-Metadata", "Separate-Worktree" });

    try tmp.dir.createDir(io, "Submodule-Source", .default_dir);
    var source = try tmp.dir.openDir(io, "Submodule-Source", .{});
    defer source.close(io);
    try runTestGit(io, source, &.{ "git", "init", "--initial-branch=main" });
    try source.writeFile(io, .{ .sub_path = "file", .data = "submodule\n" });
    try runTestGit(io, source, &.{ "git", "add", "file" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try tmp.dir.createDir(io, "Super", .default_dir);
    var super = try tmp.dir.openDir(io, "Super", .{});
    defer super.close(io);
    try runTestGit(io, super, &.{ "git", "init", "--initial-branch=main" });
    try runTestGit(io, super, &.{ "git", "-c", "protocol.file.allow=always", "submodule", "add", "../Submodule-Source", "deps/Child" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var bare_root = try openCapabilityAt(io, tmp.dir, "Bare.git");
    defer bare_root.deinit();
    var bare_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = bare_root.dir(), .environment = &environment });
    defer bare_name.deinit(std.testing.allocator);
    try std.testing.expect(bare_name == .unavailable);

    var separate_root = try openCapabilityAt(io, tmp.dir, "Separate-Worktree");
    defer separate_root.deinit();
    var separate_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = separate_root.dir(), .environment = &environment });
    defer separate_name.deinit(std.testing.allocator);
    // The agreed porcelain first-record authority reports the separate Git
    // directory as this repository's main entry; do not infer another path.
    try std.testing.expectEqualStrings("Separate-Metadata", separate_name.basename);

    var submodule_root = try openCapabilityAt(io, tmp.dir, "Super/deps/Child");
    defer submodule_root.deinit();
    var submodule_name = try mainWorktreeBasename(std.testing.allocator, io, .{ .cwd = submodule_root.dir(), .environment = &environment });
    defer submodule_name.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Child", submodule_name.basename);
}
