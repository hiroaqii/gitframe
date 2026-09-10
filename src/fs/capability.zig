//! Domain-free descriptor-relative filesystem capability mechanics.
const std = @import("std");
const builtin = @import("builtin");
pub const ObjectKind = enum { directory, regular_file, other };
pub const ExpectedKind = enum { directory, regular_file };
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
pub const Admission = struct {
    expected: ExpectedKind,
    device: u64,
    uid: u32,
    mode: u16,
    require_single_link: bool,
};
pub const AdmissionError = error{ WrongType, WrongOwner, WrongMode, CrossDevice, MultipleLinks };
pub fn admitMetadata(metadata: Metadata, admission: Admission) AdmissionError!void {
    if (metadata.device != admission.device) return error.CrossDevice;
    if (metadata.uid != admission.uid) return error.WrongOwner;
    const expected_kind: ObjectKind = switch (admission.expected) {
        .directory => .directory,
        .regular_file => .regular_file,
    };
    if (metadata.kind != expected_kind) return error.WrongType;
    if (metadata.mode != admission.mode) return error.WrongMode;
    if (admission.require_single_link and metadata.link_count != 1) return error.MultipleLinks;
}
pub const FilesystemMetadata = union(enum) {
    linux: struct { magic: isize },
    darwin: struct { flags: u32, type_name: [16]u8 },
};
pub const Descriptor = struct {
    handle: std.posix.fd_t,
    pub fn duplicate(self: Descriptor) !Descriptor {
        return .{ .handle = try duplicateCloseOnExec(self.handle) };
    }
    pub fn deinit(self: *Descriptor) void {
        _ = std.posix.system.close(self.handle);
        self.* = undefined;
    }
};
pub const File = struct {
    descriptor: Descriptor,
    metadata: Metadata,
    pub fn deinit(self: *File) void {
        self.descriptor.deinit();
        self.* = undefined;
    }
    pub fn lock(self: File, io: std.Io, kind: std.Io.File.Lock) !void {
        try self.ioFile().lock(io, kind);
    }
    pub fn tryLock(self: File, io: std.Io, kind: std.Io.File.Lock) !bool {
        return self.ioFile().tryLock(io, kind);
    }
    pub fn unlock(self: File, io: std.Io) void {
        self.ioFile().unlock(io);
    }
    fn ioFile(self: File) std.Io.File {
        return .{ .handle = self.descriptor.handle, .flags = .{ .nonblocking = true } };
    }
};
pub const Directory = struct {
    descriptor: Descriptor,
    metadata: Metadata,
    pub fn duplicate(self: Directory) !Directory {
        return .{ .descriptor = try self.descriptor.duplicate(), .metadata = self.metadata };
    }
    pub fn deinit(self: *Directory) void {
        self.descriptor.deinit();
        self.* = undefined;
    }
    pub fn openDirectory(self: Directory, name: []const u8) !Directory {
        try validateChildName(name);
        const handle = try std.posix.openat(self.descriptor.handle, name, directoryFlags(), 0);
        errdefer closeRaw(handle);
        return .{ .descriptor = .{ .handle = handle }, .metadata = try metadataForRawHandle(handle) };
    }
    pub fn openRegularFileExisting(self: Directory, name: []const u8, admission: Admission) !File {
        try validateChildName(name);
        const handle = try std.posix.openat(self.descriptor.handle, name, regularFileFlags(), 0);
        errdefer closeRaw(handle);
        const metadata = try metadataForRawHandle(handle);
        try admitMetadata(metadata, admission);
        return .{ .descriptor = .{ .handle = handle }, .metadata = metadata };
    }
    pub fn admitChild(self: Directory, name: []const u8, admission: Admission) !Metadata {
        if (admission.expected == .regular_file) {
            var file = try self.openRegularFileExisting(name, admission);
            defer file.deinit();
            return file.metadata;
        }
        var opened = try self.openDirectory(name);
        defer opened.deinit();
        try admitMetadata(opened.metadata, admission);
        return opened.metadata;
    }
    pub fn readRegularAlloc(
        self: Directory,
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        admission: Admission,
        maximum: usize,
    ) ![]u8 {
        var file = try self.openRegularFileExisting(name, admission);
        defer file.deinit();
        const before = file.metadata;
        if (before.size == 0 or before.size > maximum) return error.FileSizeOutOfBounds;
        var buffer: [4096]u8 = undefined;
        var reader = file.ioFile().reader(io, &buffer);
        const read_limit: std.Io.Limit = if (before.size == std.math.maxInt(u64))
            .unlimited
        else
            .limited64(before.size + 1);
        const bytes = try reader.interface.allocRemaining(allocator, read_limit);
        errdefer allocator.free(bytes);
        if (bytes.len != before.size) return error.FileChangedWhileReading;
        const after = try metadataForHandle(file.descriptor);
        try admitMetadata(after, admission);
        if (!before.sameObject(after) or before.size != after.size) return error.FileChangedWhileReading;
        return bytes;
    }
    pub fn iterate(_: Directory) Iterator {
        return .{};
    }
};
pub const Iterator = struct {
    state: std.Io.Dir.Reader.State = .reset,
    buffer: [std.Io.Dir.Iterator.reader_buffer_len]u8 align(@alignOf(usize)) = undefined,
    index: usize = 0,
    end: usize = 0,
    pub fn next(self: *Iterator, directory: Directory, io: std.Io) std.Io.Dir.Iterator.Error!?std.Io.Dir.Entry {
        var reader = std.Io.Dir.Reader.init(.{ .handle = directory.descriptor.handle }, &self.buffer);
        reader.state = self.state;
        reader.index = self.index;
        reader.end = self.end;
        defer {
            self.state = reader.state;
            self.index = reader.index;
            self.end = reader.end;
        }
        return reader.next(io);
    }
};
pub fn openAbsoluteRoot() !Directory {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const handle = try std.posix.openat(std.posix.AT.FDCWD, "/", directoryFlags(), 0);
    errdefer closeRaw(handle);
    return .{ .descriptor = .{ .handle = handle }, .metadata = try metadataForRawHandle(handle) };
}
pub fn validateChildName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidChildName;
}
pub fn metadataForHandle(descriptor: Descriptor) !Metadata {
    return metadataForRawHandle(descriptor.handle);
}
pub fn filesystemMetadata(directory: Directory) !FilesystemMetadata {
    return switch (builtin.os.tag) {
        .linux => filesystemMetadataForHandleLinux(directory.descriptor.handle),
        .macos => filesystemMetadataForHandleDarwin(directory.descriptor.handle),
        else => error.UnsupportedPlatform,
    };
}
fn directoryFlags() std.posix.O {
    return .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true };
}
fn regularFileFlags() std.posix.O {
    return .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true };
}
fn metadataForRawHandle(handle: std.posix.fd_t) !Metadata {
    return switch (builtin.os.tag) {
        .linux => metadataForHandleLinux(handle),
        .macos => metadataForHandleDarwin(handle),
        else => error.UnsupportedPlatform,
    };
}
fn metadataForHandleLinux(handle: std.posix.fd_t) !Metadata {
    const linux = std.os.linux;
    var statx = std.mem.zeroes(linux.Statx);
    while (true) switch (linux.errno(linux.statx(handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &statx))) {
        .SUCCESS => return .{
            .kind = if (linux.S.ISDIR(statx.mode)) .directory else if (linux.S.ISREG(statx.mode)) .regular_file else .other,
            .device = (@as(u64, statx.dev_major) << 32) | statx.dev_minor,
            .inode = statx.ino,
            .uid = statx.uid,
            .mode = @intCast(statx.mode & 0o7777),
            .link_count = statx.nlink,
            .size = statx.size,
        },
        .INTR => continue,
        .BADF => return error.InvalidCapability,
        else => return error.MetadataUnavailable,
    };
}
fn metadataForHandleDarwin(handle: std.posix.fd_t) !Metadata {
    var stat: std.c.Stat = undefined;
    while (true) {
        if (std.c.fstat(handle, &stat) == 0) {
            const mode: u16 = @intCast(stat.mode);
            return .{
                .kind = if ((mode & 0o170000) == 0o040000) .directory else if ((mode & 0o170000) == 0o100000) .regular_file else .other,
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
fn filesystemMetadataForHandleLinux(handle: std.posix.fd_t) !FilesystemMetadata {
    const linux = std.os.linux;
    var buffer: [256]u8 align(@alignOf(usize)) = [_]u8{0} ** 256;
    const rc = linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, handle))), @intFromPtr(&buffer));
    if (linux.errno(rc) != .SUCCESS) return error.FilesystemPolicyUnavailable;
    return .{ .linux = .{ .magic = @as(*align(1) const isize, @ptrCast(&buffer)).* } };
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
fn filesystemMetadataForHandleDarwin(handle: std.posix.fd_t) !FilesystemMetadata {
    var info: DarwinStatFs = undefined;
    if (fstatfs(handle, &info) != 0) return error.FilesystemPolicyUnavailable;
    return .{ .darwin = .{ .flags = info.flags, .type_name = info.type_name } };
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
test "neutral filesystem capability admits caller-supplied metadata policy" {
    const base: Metadata = .{ .kind = .directory, .device = 7, .inode = 9, .uid = 1000, .mode = 0o700, .link_count = 99, .size = 0 };
    const directory: Admission = .{ .expected = .directory, .device = 7, .uid = 1000, .mode = 0o700, .require_single_link = false };
    try admitMetadata(base, directory);
    var changed = base;
    changed.device = 8;
    try std.testing.expectError(error.CrossDevice, admitMetadata(changed, directory));
    changed = base;
    changed.uid = 1001;
    try std.testing.expectError(error.WrongOwner, admitMetadata(changed, directory));
    changed = base;
    changed.mode = 0o755;
    try std.testing.expectError(error.WrongMode, admitMetadata(changed, directory));
    changed = base;
    changed.kind = .regular_file;
    try std.testing.expectError(error.WrongType, admitMetadata(changed, directory));

    const regular: Admission = .{ .expected = .regular_file, .device = 7, .uid = 1000, .mode = 0o600, .require_single_link = true };
    changed.mode = 0o600;
    changed.link_count = 1;
    try admitMetadata(changed, regular);
    changed.link_count = 2;
    try std.testing.expectError(error.MultipleLinks, admitMetadata(changed, regular));
}

test "neutral filesystem capability opens no-follow children and reads exact stable bytes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "child", .fromMode(0o700));
    try tmp.dir.createDir(io, "swap", .fromMode(0o700));
    try tmp.dir.writeFile(io, .{ .sub_path = "value", .data = "abc", .flags = .{ .permissions = .fromMode(0o600) } });
    try tmp.dir.writeFile(io, .{ .sub_path = "linked", .data = "x", .flags = .{ .permissions = .fromMode(0o600) } });
    try tmp.dir.hardLink("linked", tmp.dir, "linked-copy", io, .{});
    try tmp.dir.symLink(io, "child", "link", .{});
    var root = try testDirectory(tmp.dir);
    defer root.deinit();
    const directory = admissionFor(root.metadata, .directory, 0o700, false);
    const regular = admissionFor(root.metadata, .regular_file, 0o600, true);
    var child = try root.openDirectory("child");
    defer child.deinit();
    try admitMetadata(child.metadata, directory);
    try std.testing.expectError(error.InvalidChildName, root.openDirectory(".."));
    try std.testing.expectError(error.InvalidChildName, root.admitChild("a/b", regular));
    try std.testing.expectError(error.MultipleLinks, root.openRegularFileExisting("linked", regular));
    try std.testing.expectError(error.FileSizeOutOfBounds, root.readRegularAlloc(std.testing.allocator, io, "value", regular, 2));
    const bytes = try root.readRegularAlloc(std.testing.allocator, io, "value", regular, 3);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abc", bytes);
    var iterator = root.iterate();
    var found_value = false;
    while (try iterator.next(root, io)) |entry| {
        if (std.mem.eql(u8, entry.name, "value")) found_value = true;
    }
    try std.testing.expect(found_value);
    if (root.openDirectory("link")) |opened_link| {
        var unexpected = opened_link;
        unexpected.deinit();
        return error.TestExpectedError;
    } else |_| {}
    try tmp.dir.rename("swap", tmp.dir, "old-swap", io);
    try tmp.dir.symLink(io, "child", "swap", .{ .is_directory = true });
    if (root.openDirectory("swap")) |opened_swap| {
        var unexpected = opened_swap;
        unexpected.deinit();
        return error.TestExpectedError;
    } else |_| {}
}

fn admissionFor(metadata: Metadata, expected: ExpectedKind, mode: u16, single_link: bool) Admission {
    return .{ .expected = expected, .device = metadata.device, .uid = metadata.uid, .mode = mode, .require_single_link = single_link };
}

fn testDirectory(dir: std.Io.Dir) !Directory {
    const handle = try std.posix.openat(dir.handle, ".", directoryFlags(), 0);
    errdefer closeRaw(handle);
    return .{ .descriptor = .{ .handle = handle }, .metadata = try metadataForRawHandle(handle) };
}
