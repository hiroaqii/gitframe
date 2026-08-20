//! Descriptor-relative, no-follow admission for the read-only Review Store.

const std = @import("std");
const builtin = @import("builtin");
const store_path = @import("path.zig");

pub const ObjectKind = enum { directory, regular_file, other };

pub const Metadata = struct {
    kind: ObjectKind,
    device: u64,
    inode: u64,
    uid: u32,
    mode: u16,
    link_count: u64,
    size: u64,

    pub fn sameObject(left: Metadata, right: Metadata) bool {
        return left.device == right.device and left.inode == right.inode;
    }
};

pub const ExpectedKind = enum { directory, regular_file };

pub const PolicyError = error{
    WrongType,
    WrongOwner,
    WrongMode,
    CrossDevice,
    MultipleLinks,
};

/// Pure policy seam. Directory link counts intentionally never participate.
pub fn admitMetadata(
    metadata: Metadata,
    expected: ExpectedKind,
    root_device: u64,
    effective_uid: u32,
) PolicyError!void {
    if (metadata.device != root_device) return error.CrossDevice;
    if (metadata.uid != effective_uid) return error.WrongOwner;
    switch (expected) {
        .directory => {
            if (metadata.kind != .directory) return error.WrongType;
            if (metadata.mode != 0o700) return error.WrongMode;
        },
        .regular_file => {
            if (metadata.kind != .regular_file) return error.WrongType;
            if (metadata.mode != 0o600) return error.WrongMode;
            if (metadata.link_count != 1) return error.MultipleLinks;
        },
    }
}

pub const FilesystemPolicy = enum {
    local_supported,
    unsupported,

    pub fn fromLinuxMagic(magic: u64) FilesystemPolicy {
        return switch (magic) {
            0x0000ef53, // ext2/3/4
            0x58465342, // XFS
            0x9123683e, // Btrfs
            0xf2f52010, // F2FS
            0x2fc12fc1, // ZFS
            0x01021994, // tmpfs
            0x858458f6, // ramfs
            0x794c7630, // overlayfs
            => .local_supported,
            else => .unsupported,
        };
    }
};

pub const DirectoryCapability = struct {
    handle: std.posix.fd_t,
    metadata: Metadata,
    effective_uid: u32,
    root_device: u64,

    pub fn dir(self: DirectoryCapability) std.Io.Dir {
        return .{ .handle = self.handle };
    }

    pub fn duplicate(self: DirectoryCapability) !DirectoryCapability {
        return .{
            .handle = try duplicateCloseOnExec(self.handle),
            .metadata = self.metadata,
            .effective_uid = self.effective_uid,
            .root_device = self.root_device,
        };
    }

    pub fn deinit(self: *DirectoryCapability) void {
        closeRaw(self.handle);
        self.* = undefined;
    }

    pub fn openDirectory(self: DirectoryCapability, name: []const u8) !DirectoryCapability {
        try validateChildName(name);
        const handle = try std.posix.openat(self.handle, name, directoryFlags(), 0);
        errdefer closeRaw(handle);
        const metadata = try metadataForHandle(handle);
        try admitMetadata(metadata, .directory, self.root_device, self.effective_uid);
        return .{
            .handle = handle,
            .metadata = metadata,
            .effective_uid = self.effective_uid,
            .root_device = self.root_device,
        };
    }

    /// Admit an expected child without consuming its contents.
    pub fn admitChild(self: DirectoryCapability, name: []const u8, expected: ExpectedKind) !Metadata {
        try validateChildName(name);
        const handle = try std.posix.openat(
            self.handle,
            name,
            if (expected == .directory) directoryFlags() else regularFileFlags(),
            0,
        );
        defer closeRaw(handle);
        const metadata = try metadataForHandle(handle);
        try admitMetadata(metadata, expected, self.root_device, self.effective_uid);
        return metadata;
    }

    /// Read one exact regular authority file and close name/object replacement
    /// races by checking the same descriptor again after EOF.
    pub fn readRegularAlloc(
        self: DirectoryCapability,
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        maximum: usize,
    ) ![]u8 {
        try validateChildName(name);
        const handle = try std.posix.openat(self.handle, name, regularFileFlags(), 0);
        defer closeRaw(handle);
        const before = try metadataForHandle(handle);
        try admitMetadata(before, .regular_file, self.root_device, self.effective_uid);
        if (before.size == 0 or before.size > maximum) return error.FileSizeOutOfBounds;

        var buffer: [4096]u8 = undefined;
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        var file_reader = file.reader(io, &buffer);
        const bytes = try file_reader.interface.allocRemaining(allocator, .limited(maximum));
        errdefer allocator.free(bytes);
        if (bytes.len != before.size) return error.FileChangedWhileReading;
        const after = try metadataForHandle(handle);
        try admitMetadata(after, .regular_file, self.root_device, self.effective_uid);
        if (!before.sameObject(after) or before.size != after.size) return error.FileChangedWhileReading;
        return bytes;
    }
};

pub const StoreRootCapability = struct {
    directory: DirectoryCapability,
    filesystem: FilesystemPolicy,

    pub fn openCanonical(path: []const u8) !StoreRootCapability {
        try store_path.validateAbsoluteCanonical(path);
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;

        var current = try std.posix.openat(std.posix.AT.FDCWD, "/", directoryFlags(), 0);
        errdefer closeRaw(current);
        var components = std.mem.splitScalar(u8, path[1..], '/');
        while (components.next()) |component| {
            const child = try std.posix.openat(current, component, directoryFlags(), 0);
            closeRaw(current);
            current = child;
        }
        const metadata = try metadataForHandle(current);
        const uid = effectiveUid();
        try admitMetadata(metadata, .directory, metadata.device, uid);
        const filesystem = try filesystemForHandle(current);
        if (filesystem != .local_supported) return error.UnsupportedFilesystem;
        return .{ .directory = .{
            .handle = current,
            .metadata = metadata,
            .effective_uid = uid,
            .root_device = metadata.device,
        }, .filesystem = filesystem };
    }

    pub fn deinit(self: *StoreRootCapability) void {
        self.directory.deinit();
        self.* = undefined;
    }
};

fn validateChildName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidChildName;
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

fn regularFileFlags() std.posix.O {
    return .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    };
}

fn effectiveUid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.geteuid()),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn metadataForHandle(handle: std.posix.fd_t) !Metadata {
    return switch (builtin.os.tag) {
        .linux => metadataForHandleLinux(handle),
        .macos => metadataForHandleDarwin(handle),
        else => error.UnsupportedPlatform,
    };
}

fn metadataForHandleLinux(handle: std.posix.fd_t) !Metadata {
    const linux = std.os.linux;
    var statx = std.mem.zeroes(linux.Statx);
    while (true) {
        const rc = linux.statx(handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &statx);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const kind: ObjectKind = if (linux.S.ISDIR(statx.mode))
                    .directory
                else if (linux.S.ISREG(statx.mode))
                    .regular_file
                else
                    .other;
                return .{
                    .kind = kind,
                    .device = (@as(u64, statx.dev_major) << 32) | statx.dev_minor,
                    .inode = statx.ino,
                    .uid = statx.uid,
                    .mode = @intCast(statx.mode & 0o7777),
                    .link_count = statx.nlink,
                    .size = statx.size,
                };
            },
            .INTR => continue,
            .BADF => return error.InvalidCapability,
            else => return error.MetadataUnavailable,
        }
    }
}

fn metadataForHandleDarwin(handle: std.posix.fd_t) !Metadata {
    var stat: std.c.Stat = undefined;
    while (true) {
        if (std.c.fstat(handle, &stat) == 0) {
            const mode: u16 = @intCast(stat.mode);
            const kind: ObjectKind = if ((mode & 0o170000) == 0o040000)
                .directory
            else if ((mode & 0o170000) == 0o100000)
                .regular_file
            else
                .other;
            return .{
                .kind = kind,
                .device = @as(u32, @bitCast(stat.dev)),
                .inode = @intCast(stat.ino),
                .uid = @intCast(stat.uid),
                .mode = mode & 0o7777,
                .link_count = @intCast(stat.nlink),
                .size = @intCast(stat.size),
            };
        }
        switch (std.c._errno().*) {
            @intFromEnum(std.c.E.INTR) => continue,
            @intFromEnum(std.c.E.BADF) => return error.InvalidCapability,
            else => return error.MetadataUnavailable,
        }
    }
}

fn filesystemForHandle(handle: std.posix.fd_t) !FilesystemPolicy {
    return switch (builtin.os.tag) {
        .linux => filesystemForHandleLinux(handle),
        .macos => filesystemForHandleDarwin(handle),
        else => error.UnsupportedPlatform,
    };
}

fn filesystemForHandleLinux(handle: std.posix.fd_t) !FilesystemPolicy {
    const linux = std.os.linux;
    var buffer: [256]u8 align(@alignOf(usize)) = [_]u8{0} ** 256;
    const rc = linux.syscall2(
        .fstatfs,
        @as(usize, @bitCast(@as(isize, handle))),
        @intFromPtr(&buffer),
    );
    if (linux.errno(rc) != .SUCCESS) return error.FilesystemPolicyUnavailable;
    const magic = @as(*align(1) const isize, @ptrCast(&buffer)).*;
    if (magic < 0) return .unsupported;
    return FilesystemPolicy.fromLinuxMagic(@intCast(magic));
}

const DarwinStatFs = extern struct {
    block_size: u32,
    io_size: i32,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    fsid: [2]i32,
    owner: u32,
    fs_type: u32,
    flags: u32,
    fs_subtype: u32,
    type_name: [16]u8,
    mounted_on: [1024]u8,
    mounted_from: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

extern "c" fn fstatfs(fd: std.c.fd_t, output: *DarwinStatFs) c_int;

fn filesystemForHandleDarwin(handle: std.posix.fd_t) !FilesystemPolicy {
    var info: DarwinStatFs = undefined;
    if (fstatfs(handle, &info) != 0) return error.FilesystemPolicyUnavailable;
    const mnt_read_only: u32 = 0x00000001;
    const mnt_local: u32 = 0x00001000;
    if ((info.flags & mnt_local) == 0 or (info.flags & mnt_read_only) != 0) return .unsupported;
    const type_name = std.mem.sliceTo(&info.type_name, 0);
    if (std.ascii.eqlIgnoreCase(type_name, "fusefs") or
        std.ascii.eqlIgnoreCase(type_name, "osxfuse") or
        std.ascii.eqlIgnoreCase(type_name, "macfuse")) return .unsupported;
    return .local_supported;
}

fn duplicateCloseOnExec(handle: std.posix.fd_t) !std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.fcntl(handle, std.posix.F.DUPFD_CLOEXEC, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.InvalidCapability,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.DuplicateCapabilityFailed,
        }
    }
}

fn closeRaw(handle: std.posix.fd_t) void {
    _ = std.posix.system.close(handle);
}

test "review history backend metadata policy ignores directory link count only" {
    const base: Metadata = .{
        .kind = .directory,
        .device = 7,
        .inode = 9,
        .uid = 1000,
        .mode = 0o700,
        .link_count = 1,
        .size = 0,
    };
    for ([_]u64{ 1, 2, 99 }) |links| {
        var directory = base;
        directory.link_count = links;
        try admitMetadata(directory, .directory, 7, 1000);
    }
    var file = base;
    file.kind = .regular_file;
    file.mode = 0o600;
    file.link_count = 1;
    try admitMetadata(file, .regular_file, 7, 1000);
    file.link_count = 2;
    try std.testing.expectError(error.MultipleLinks, admitMetadata(file, .regular_file, 7, 1000));
}

test "review history backend filesystem policy fails unknown and shared magic closed" {
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x0000ef53));
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x01021994));
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x794c7630));
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x6969)); // NFS
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0xff534d42)); // CIFS
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x65735546)); // FUSE
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x12345678));
}

test "review history backend descriptor admission reopens private nested layout" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store_dir = try tmp.dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    try store_dir.createDir(io, "123e4567-e89b-42d3-a456-426614174000", .fromMode(0o700));
    var namespace = try store_dir.openDir(io, "123e4567-e89b-42d3-a456-426614174000", .{});
    defer namespace.close(io);
    try namespace.writeFile(io, .{
        .sub_path = "registry.json",
        .data = "x",
        .flags = .{ .permissions = .fromMode(0o600) },
    });

    const root_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(root_path);
    var root = try StoreRootCapability.openCanonical(root_path);
    defer root.deinit();
    var child = try root.directory.openDirectory("123e4567-e89b-42d3-a456-426614174000");
    defer child.deinit();
    const metadata = try child.admitChild("registry.json", .regular_file);
    try std.testing.expectEqual(ObjectKind.regular_file, metadata.kind);
}
