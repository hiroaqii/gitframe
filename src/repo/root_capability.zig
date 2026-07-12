const std = @import("std");
const builtin = @import("builtin");

pub const Identity = struct {
    device: u64,
    inode: u64,

    pub fn eql(left: Identity, right: Identity) bool {
        return left.device == right.device and left.inode == right.inode;
    }
};

/// Owned descriptor for the physical repository root committed by the shell.
///
/// Construction walks from `/` with no-follow directory opens. Async work gets
/// an independent duplicate and never reopens the root path as authority.
pub const RootCapability = struct {
    handle: std.posix.fd_t,
    identity: Identity,

    pub fn openCanonical(path: []const u8) !RootCapability {
        return switch (builtin.os.tag) {
            .linux, .macos => openSupported(path),
            else => error.UnsupportedPlatform,
        };
    }

    pub fn duplicate(self: RootCapability) !RootCapability {
        return .{
            .handle = try duplicateCloseOnExec(self.handle),
            .identity = self.identity,
        };
    }

    pub fn dir(self: RootCapability) std.Io.Dir {
        return .{ .handle = self.handle };
    }

    pub fn deinit(self: *RootCapability) void {
        closeRaw(self.handle);
        self.* = undefined;
    }
};

fn currentIdentity(path: []const u8) !Identity {
    var capability = try RootCapability.openCanonical(path);
    defer capability.deinit();
    return capability.identity;
}

pub fn pathMatches(path: []const u8, expected: Identity) bool {
    const current = currentIdentity(path) catch return false;
    return current.eql(expected);
}

fn openSupported(path: []const u8) !RootCapability {
    if (path.len == 0 or path[0] != '/') return error.RootNotAbsolute;

    var current = try std.posix.openat(std.posix.AT.FDCWD, "/", directoryFlags(), 0);
    errdefer closeRaw(current);
    if (path.len > 1) {
        var components = std.mem.splitScalar(u8, path[1..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
                return error.InvalidCanonicalRoot;
            }
            const child = try std.posix.openat(current, component, directoryFlags(), 0);
            closeRaw(current);
            current = child;
        }
    }

    return .{
        .handle = current,
        .identity = try identityForHandle(current),
    };
}

fn directoryFlags() std.posix.O {
    return .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    };
}

fn duplicateCloseOnExec(handle: std.posix.fd_t) !std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.fcntl(handle, std.posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.InvalidRootCapability,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateRootCapabilityFailed,
        }
    }
}

fn identityForHandle(handle: std.posix.fd_t) !Identity {
    return switch (builtin.os.tag) {
        .linux => identityForHandleLinux(handle),
        .macos => identityForHandleDarwin(handle),
        else => error.UnsupportedPlatform,
    };
}

fn identityForHandleLinux(handle: std.posix.fd_t) !Identity {
    const linux = std.os.linux;
    var statx = std.mem.zeroes(linux.Statx);
    while (true) {
        const rc = linux.statx(handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &statx);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{
                .device = (@as(u64, statx.dev_major) << 32) | statx.dev_minor,
                .inode = statx.ino,
            },
            .INTR => continue,
            .BADF => return error.InvalidRootCapability,
            else => return error.RootIdentityUnavailable,
        }
    }
}

fn identityForHandleDarwin(handle: std.posix.fd_t) !Identity {
    var stat: std.c.Stat = undefined;
    while (true) {
        const rc = std.c.fstat(handle, &stat);
        if (rc == 0) {
            return .{
                .device = @as(u32, @bitCast(stat.dev)),
                .inode = @intCast(stat.ino),
            };
        }
        switch (std.c._errno().*) {
            @intFromEnum(std.c.E.INTR) => continue,
            @intFromEnum(std.c.E.BADF) => return error.InvalidRootCapability,
            else => return error.RootIdentityUnavailable,
        }
    }
}

fn closeRaw(handle: std.posix.fd_t) void {
    _ = std.posix.system.close(handle);
}

test "root capability pins a physical directory object" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root);

    var capability = try RootCapability.openCanonical(root);
    defer capability.deinit();
    var duplicate = try capability.duplicate();
    defer duplicate.deinit();

    try std.testing.expect(capability.identity.eql(duplicate.identity));
    try std.testing.expect(pathMatches(root, capability.identity));
}

test "root capability rejects a symlink component" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.symLink(io, "target", "linked", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const linked = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(linked);

    if (RootCapability.openCanonical(linked)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.ExpectedSymlinkRejection;
    } else |err| switch (err) {
        error.SymLinkLoop, error.NotDir => {},
        else => return err,
    }
}

test "root capability is not redirected by final root replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try RootCapability.openCanonical(root_path);
    defer root.deinit();

    try tmp.dir.rename("repo", tmp.dir, "old-repo", io);
    try tmp.dir.symLink(io, "outside", "repo", .{ .is_directory = true });

    try std.testing.expect(!pathMatches(root_path, root.identity));
    var duplicate = try root.duplicate();
    defer duplicate.deinit();
    try std.testing.expect(duplicate.identity.eql(root.identity));
}

test "root capability is not redirected by ancestor replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "base", .default_dir);
    var base = try tmp.dir.openDir(io, "base", .{});
    defer base.close(io);
    try base.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    var outside = try tmp.dir.openDir(io, "outside", .{});
    defer outside.close(io);
    try outside.createDir(io, "repo", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, "base/repo", allocator);
    defer allocator.free(root_path);
    var root = try RootCapability.openCanonical(root_path);
    defer root.deinit();

    try tmp.dir.rename("base", tmp.dir, "old-base", io);
    try tmp.dir.symLink(io, "outside", "base", .{ .is_directory = true });

    try std.testing.expect(!pathMatches(root_path, root.identity));
    var duplicate = try root.duplicate();
    defer duplicate.deinit();
    try std.testing.expect(duplicate.identity.eql(root.identity));
}
